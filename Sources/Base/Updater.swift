import AppKit
import BaseCore
import Combine
import Security

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
/// 4. Install: the old app goes to the Trash, the new one takes its place, and it restarts.
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
            try Self.verify(newApp, expectedVersion: release.version)
            let target = await MainActor.run { Bundle.main.bundleURL }
            try Self.replace(target, with: newApp)
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

    /// The downloaded app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The update isn't a valid app.")
        }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("Couldn't check the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The update isn't signed by Maben. It was not installed.")
        }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Swaps the app bundle. The old copy goes to the Trash, so it can be restored by hand.
    nonisolated static func replace(_ target: URL, with newApp: URL) throws {
        let fm = FileManager.default
        if fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path) {
            var trashed: NSURL?
            try fm.trashItem(at: target, resultingItemURL: &trashed)
            do {
                try fm.copyItem(at: newApp, to: target)
            } catch {
                if let trashed { try? fm.moveItem(at: trashed as URL, to: target) }   // put the old one back
                throw Failure("Couldn't install the update: \(error.localizedDescription)")
            }
        } else {
            // Installed by an administrator: ask for the password once.
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let staged = target.deletingLastPathComponent().appendingPathComponent(".Maben Base.update.app").path
            let command = "/bin/rm -rf \(q(staged)) && /usr/bin/ditto \(q(newApp.path)) \(q(staged)) && /bin/rm -rf \(q(target.path)) && /bin/mv \(q(staged)) \(q(target.path))"
            let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with prompt \"Maben Base wants to install an update.\" with administrator privileges"
            guard run("/usr/bin/osascript", ["-e", script]) == 0 else { throw Failure("The update was not installed (no administrator password).") }
        }
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
    nonisolated static func verifyIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count else { return }
        do {
            try verify(URL(fileURLWithPath: args[i + 1]), expectedVersion: args[i + 2])
            print("ACCEPTED")
        } catch {
            print("REJECTED: \((error as? Failure)?.message ?? "\(error)")")
        }
        exit(0)
    }
}
