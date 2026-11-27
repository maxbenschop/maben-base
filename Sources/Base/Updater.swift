import AppKit
import BaseCore
import Combine

/// True for the built app, false for `swift run` and tests.
let isBundled = Bundle.main.bundleURL.pathExtension == "app"

/// Updates from GitHub Releases (github.com/maxbenschop/maben-base), the same way Maben Awake and Maben Sweep do.
///
/// 1. Check: ask the GitHub API for the latest release (drafts and pre-releases are never "latest").
///    Its tag `vX.Y.Z` is the version and its text the release notes. At start, every 6 hours, after
///    waking if the last check is over 6 hours old, and when you press Check now. Apart from your
///    databases, this is the only network request the app makes.
/// 2. Download `Maben-Base.zip` from that release to a temporary folder.
/// 3. Verify before touching anything: the app inside must be signed with the Developer ID of team
///    NJTYRVLSA8 with this bundle ID, notarized by Apple (Gatekeeper accepts it), and the announced version.
/// 4. Install: copy the new app next to the old one, verify that copy again (it is the one that goes in),
///    and swap the two; the old app then goes to the Trash. Only if the app folder isn't writable does it
///    ask for an administrator password, and then root makes its own copy and checks that. Then it restarts.
///
/// An automatic install never restarts the app under your hands: it waits until no connection window is
/// open, or runs as you quit (then the new version is simply there next time).
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    typealias Release = ReleaseFeed.Release

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "updates.autoCheck"); schedule() } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "updates.autoInstall") } }

    nonisolated static let teamID = "NJTYRVLSA8"
    nonisolated static let bundleID = "gg.maben.base"

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastCheck: Date?
    private var wakeObserver: NSObjectProtocol?
    private var downloadObservation: NSKeyValueObservation?
    /// Set while an update installs as the app quits: called when it is done, whatever the outcome.
    private var afterInstall: (() -> Void)?
    private var quitting = false

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r): r
        default: nil
        }
    }

    /// Updates only install over a copy in an Applications folder (not a dev build or a translocated download).
    var canInstall: Bool {
        let path = Bundle.main.bundlePath
        return isBundled && !path.contains("/AppTranslocation/")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    /// The demo and development copies never check or install.
    private var live: Bool { isBundled && !CommandLine.arguments.contains("--demo") }

    private init() {
        // On by default, as in Maben Awake and Maben Sweep.
        autoCheck = defaults.object(forKey: "updates.autoCheck") as? Bool ?? true
        autoInstall = defaults.object(forKey: "updates.autoInstall") as? Bool ?? true
    }

    /// Call once at launch. Does nothing for a copy that isn't a real app (`swift run`, tests, demo).
    func start() {
        guard live else { return }
        if canInstall { Self.removeLeftovers(beside: Bundle.main.bundleURL) }
        schedule()
        if autoCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    private func checkAfterWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoCheck else { return }
            if let lastCheck = self.lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
            self.check(userInitiated: false)
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard autoCheck, live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: ReleaseFeed.url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MabenBase/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { ReleaseFeed.parse($0) }
            Task { @MainActor in
                if let error {
                    self.fail(userInitiated ? "Couldn't reach GitHub: \(error.localizedDescription)" : nil)
                } else if status != 200 || release == nil {
                    self.fail(userInitiated ? "GitHub didn't return a release (HTTP \(status))." : nil)
                } else if let release, ReleaseFeed.isNewer(release.version, than: self.currentVersion) {
                    self.lastCheck = Date()
                    self.state = .available(release)
                    if self.autoInstall { self.installWhenQuiet() }
                } else {
                    self.lastCheck = Date()
                    self.state = .upToDate(checked: Date())
                }
            }
        }.resume()
    }

    private func fail(_ message: String?) {
        state = message.map { .failed($0) } ?? .idle
    }

    // MARK: Install

    /// Automatic install: only while no connection window is open, so nothing you are looking at is lost.
    private func installWhenQuiet() {
        guard canInstall else { return }
        if WorkspaceWindowController.open.isEmpty {
            install()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, case .available = self.state, self.autoInstall else { return }
                self.installWhenQuiet()
            }
        }
    }

    /// As the app quits: installs a waiting update without restarting, then calls `done`.
    /// Returns false (and does nothing) when there is no update to install automatically.
    func installOnQuit(_ done: @escaping () -> Void) -> Bool {
        guard autoInstall, canInstall, case .available = state else { return false }
        afterInstall = done
        quitting = true
        // Never keep the app from quitting: give up after 45 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.finished() }
        install()
        return true
    }

    /// The Update button: restarting drops edits that haven't been saved, so it asks first when there are any.
    func update() {
        let dirty = WorkspaceWindowController.open.filter { $0.workspace.hasUnsavedChanges }
        if !dirty.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Update with unsaved changes?"
            alert.informativeText = "Maben Base restarts to update. Edited rows in \(dirty.map { $0.workspace.config.displayName }.joined(separator: ", ")) haven't been written to the database and would be lost."
            alert.addButton(withTitle: "Update anyway").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        install()
    }

    /// Downloads, verifies and swaps the app, then restarts (or lets a waiting quit go on).
    private func install() {
        guard let release = available, canInstall else { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .downloading(release, progress: 0)
        let task = URLSession.shared.downloadTask(with: release.zip) { location, response, error in
            // The temporary file is deleted when this returns, so move it first.
            var kept: URL?
            if let location {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MabenBase-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { kept = dest }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard let kept, error == nil, status == 200 else {
                    self.state = .failed("The download failed\(error.map { ": \($0.localizedDescription)" } ?? " (HTTP \(status)).")")
                    self.finished()
                    return
                }
                self.state = .installing(release)
                Task.detached { await self.finish(zip: kept, release: release) }
            }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading(let r, _) = self.state { self.state = .downloading(r, progress: value) }
            }
        }
        task.resume()
    }

    /// Unpacks, verifies and swaps the app. Runs off the main thread.
    private nonisolated func finish(zip: URL, release: Release) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MabenBaseUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: zip) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw Failure("Couldn't unpack the update.") }
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw Failure("The update doesn't contain an app.") }
            // Checked here first, so a bad download never gets as far as a password prompt.
            try Self.verify(newApp, expectedVersion: release.version)
            let target = await MainActor.run { Bundle.main.bundleURL }
            try Self.replace(target, with: newApp, version: release.version) { try Self.verify($0, expectedVersion: release.version) }
            try? fm.removeItem(at: work)
            await MainActor.run {
                if self.quitting { self.finished() } else { self.relaunch() }
            }
        } catch {
            try? fm.removeItem(at: work)
            let message = (error as? Failure)?.message ?? error.localizedDescription
            await MainActor.run {
                self.state = .failed(message)
                self.finished()
            }
        }
    }

    /// Lets a waiting quit go on (once).
    private func finished() {
        let done = afterInstall
        afterInstall = nil
        done?()
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// What an update must be, as a code requirement: signed with a Developer ID (not a development or App
    /// Store certificate) of our team, under our bundle ID, and notarized by Apple, whatever this Mac's
    /// Gatekeeper setting is. The one text for the check in this process and for the check root runs on its
    /// own copy.
    nonisolated static func requirement(identifiers: [String] = [bundleID]) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and \(CodeSignature.identifiers(identifiers)) and notarized"
    }

    nonisolated static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// The app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        guard CodeSignature.satisfies(app, requirement()) else {
            throw Failure("The update isn't signed by Maben and notarized by Apple. It was not installed.")
        }
        // Gatekeeper's own answer as well: it also knows what Apple has revoked.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        guard version(of: app) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Hidden names beside the app while it is swapped: the copy going in, and the app going out.
    nonisolated static let stagedName = ".Maben Base.update.app"
    nonisolated static let oldName = ".Maben Base.old.app"

    /// Puts `newApp` (which has `version`) in place of `target`. `check` runs on the copy that goes in and
    /// throws if it may not.
    nonisolated static func replace(_ target: URL, with newApp: URL, version: String, askForPassword: Bool = true,
                                    check: (URL) throws -> Void, discard: (URL) -> Void = Updater.trash) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path) {
            try swap(target, with: newApp, check: check, discard: discard)
        } else if !askForPassword {
            throw Failure("The app folder isn't writable without an administrator password.")
        } else {
            // Installed by an administrator: ask for the password once. Root copies, checks and swaps (`rootInstallCommand`).
            let command = rootInstallCommand(newApp: newApp.path, target: target.path, requirement: requirement(),
                                             version: version, token: UUID().uuidString)
            switch AdminShell.runAndWait(command, prompt: "Maben Base wants to install an update.") {
            case .done: break
            case .cancelled: throw Failure("The update was not installed (no administrator password).")
            case .failed: throw Failure("The update was not installed: it couldn't be copied or didn't pass the checks.")
            }
        }
    }

    /// Swaps the app in a folder we can write to. The new app is first copied next to the old one and
    /// `check` runs on that copy: what was checked is what goes in, whatever happens to `newApp` meanwhile.
    /// Then two renames, and if the second fails the old app goes back, so the app is never missing after a
    /// failure. Only after that does the old copy leave (`discard`: to the Trash).
    /// (`move` is only replaced by the tests.)
    nonisolated static func swap(_ target: URL, with newApp: URL, check: (URL) throws -> Void,
                                 move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                                 discard: (URL) -> Void = Updater.trash) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(stagedName), old = folder.appendingPathComponent(oldName)
        func failure(_ error: Error) -> Failure {
            try? fm.removeItem(at: staged)
            return (error as? Failure) ?? Failure("Couldn't install the update: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: staged)   // left by a swap that was cut short
        do {
            try fm.copyItem(at: newApp, to: staged)
            try check(staged)
        } catch {
            throw failure(error)
        }
        try? fm.removeItem(at: old)
        do { try move(target, old) } catch { throw failure(error) }
        do {
            try move(staged, target)
        } catch {
            try? move(old, target)   // put the old one back
            throw failure(error)
        }
        discard(old)
    }

    /// The old app goes to the Trash under its own name, so it can be put back by hand. If that can't be
    /// done it is removed: a hidden copy must not stay beside the app.
    nonisolated static func trash(_ old: URL) {
        let fm = FileManager.default
        // In the Trash a name that starts with a dot would be invisible, so it gets its name back first,
        // in a folder of its own on the same disk.
        if let holder = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: old, create: true) {
            let named = holder.appendingPathComponent("Maben Base.app")
            if (try? fm.moveItem(at: old, to: named)) != nil {
                if (try? fm.trashItem(at: named, resultingItemURL: nil)) == nil { try? fm.removeItem(at: named) }
            }
            try? fm.removeItem(at: holder)
        }
        if fm.fileExists(atPath: old.path), (try? fm.trashItem(at: old, resultingItemURL: nil)) == nil { try? fm.removeItem(at: old) }
    }

    /// A swap that was cut short (power loss, force quit) leaves a hidden copy beside the app.
    nonisolated static func removeLeftovers(beside target: URL) {
        for name in [stagedName, oldName] {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent().appendingPathComponent(name))
        }
    }

    /// The shell command root runs to install an update where the app folder isn't writable. What this
    /// process checked proves nothing to root: the download is in a folder the user's other processes can
    /// write to. So root copies it into a folder of its own next to the app (mode 700 from the moment it
    /// exists, so nobody else can reach inside), checks that copy (signature, Gatekeeper, version) and swaps
    /// it in with two renames. Any failure removes the folder and leaves the app as it was.
    /// `token` makes the folder's name; it must be new every time.
    nonisolated static func rootInstallCommand(newApp: String, target: String, requirement: String, version: String, token: String) -> String {
        let q = AdminShell.quote
        let folder = (target as NSString).deletingLastPathComponent
        return [
            "T=\(q(target))",
            "D=\(q(folder + "/.Maben Base.update." + token))",
            #"S="$D/Maben Base.app""#,
            #"fail() { /bin/rm -rf "$D"; exit 1; }"#,
            // Not `fail`: a folder that was already there isn't ours to remove.
            #"/bin/mkdir -m 700 "$D" || exit 1"#,
            #"/usr/bin/ditto \#(q(newApp)) "$S" || fail"#,
            // The new app belongs to whoever owned the old one, and brings no set-user-ID bit of its own making.
            #"/usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail"#,
            #"/bin/chmod -R ug-s "$S" || fail"#,
            #"/usr/bin/codesign --verify --deep --strict -R=\#(q(requirement)) "$S" || fail"#,
            #"/usr/sbin/spctl --assess --type execute "$S" || fail"#,
            #"[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = \#(q(version)) ] || fail"#,
            #"/bin/mv "$T" "$D/old.app" || fail"#,
            // If the old app can't go back either, it stays in the folder: never `fail` with the only copy in there.
            #"/bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }"#,
            #"/bin/rm -rf "$D""#,
            "exit 0",
        ].joined(separator: "\n")
    }

    /// Opens the new version a second after this one quits. The open connections and tabs are saved first,
    /// so they come back.
    private func relaunch() {
        SessionMemory.save()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        exit(0)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// `Base --verify-update <app> <version>`: runs the updater's checks on an app and prints the result.
    /// A development build only (see `DevelopmentFlags`).
    nonisolated static func verifyIfRequested() {
        let args = CommandLine.arguments
        guard DevelopmentFlags.allowed, let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count else { return }
        do {
            try verify(URL(fileURLWithPath: args[i + 1]), expectedVersion: args[i + 2])
            print("ACCEPTED")
        } catch {
            print("REJECTED: \((error as? Failure)?.message ?? "\(error)")")
        }
        exit(0)
    }
}
