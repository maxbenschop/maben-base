@testable import Base
import BaseCore
import XCTest

/// The updater's checks and the swap, with stand-in apps in a temporary folder and, where one is installed,
/// the notarized release in /Applications (read only: it is copied, never changed).
final class UpdaterTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("maben-base-updater-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: dir)
    }

    /// An unsigned stand-in for the app: a folder with a version in its Info.plist.
    @discardableResult
    private func makeApp(_ path: String, version: String) throws -> URL {
        let app = dir.appendingPathComponent(path)
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["CFBundleShortVersionString": version]).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func names(in folder: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: folder.path).sorted() }

    /// In place of the Trash, so the tests leave nothing there.
    private func remove(_ old: URL) { try? fm.removeItem(at: old) }

    // MARK: What an update must be

    func testRequirementAsksForOurDeveloperIDAndNotarization() {
        XCTAssertEqual(Updater.requirement(),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                       + " and certificate leaf[subject.OU] = \"NJTYRVLSA8\" and (identifier \"gg.maben.base\") and notarized")
        XCTAssertEqual(CodeSignature.identifiers(["gg.maben.base", "x\" or anchor apple", ""]), "(identifier \"gg.maben.base\")",
                       "an ID that could change the requirement is left out")
    }

    func testAnUnsignedAppIsNotAnUpdate() throws {
        let app = try makeApp("Maben Base.app", version: "9.9")
        XCTAssertThrowsError(try Updater.verify(app, expectedVersion: "9.9"))
    }

    /// The release that is installed on this Mac, if any, is what a real update looks like.
    private func installedRelease() throws -> URL {
        let app = URL(fileURLWithPath: "/Applications/Maben Base.app")
        guard CodeSignature.satisfies(app, Updater.requirement()) else { throw XCTSkip("no notarized Maben Base in /Applications") }
        return app
    }

    func testANotarizedReleasePassesAndOnlyAsItsOwnVersion() throws {
        let app = try installedRelease()
        let version = try XCTUnwrap(Updater.version(of: app))
        XCTAssertNoThrow(try Updater.verify(app, expectedVersion: version))
        XCTAssertThrowsError(try Updater.verify(app, expectedVersion: version + ".1"))
        XCTAssertFalse(CodeSignature.satisfies(app, Updater.requirement(identifiers: ["gg.maben.other"])), "the same app under another bundle ID")
    }

    func testAReleaseThatWasChangedIsNotAnUpdate() throws {
        let copy = dir.appendingPathComponent("Maben Base.app")
        try fm.copyItem(at: try installedRelease(), to: copy)
        let version = try XCTUnwrap(Updater.version(of: copy))
        XCTAssertNoThrow(try Updater.verify(copy, expectedVersion: version))
        let resources = copy.appendingPathComponent("Contents/Resources")
        let file = resources.appendingPathComponent(try XCTUnwrap(try names(in: resources).first))
        var data = try Data(contentsOf: file)
        data.append(0)
        try data.write(to: file)
        XCTAssertThrowsError(try Updater.verify(copy, expectedVersion: version))
    }

    // MARK: Swapping the app in a writable folder

    /// Swapping leaves the new app in place and no hidden copy beside it, the old app is handed over only
    /// after the new one is in, and what was checked is the copy that went in.
    func testSwapPutsTheCheckedCopyInPlace() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        var checked: [URL] = [], discarded: [String] = []
        try Updater.replace(target, with: new, version: "0.3", askForPassword: false, check: { checked.append($0) }, discard: { old in
            XCTAssertEqual(Updater.version(of: target), "0.3", "the new app is in place before the old one leaves")
            discarded.append("\(old.lastPathComponent) \(Updater.version(of: old) ?? "")")
            self.remove(old)
        })
        XCTAssertEqual(checked.map(\.lastPathComponent), [".Maben Base.update.app"])
        XCTAssertEqual(checked.first?.deletingLastPathComponent().path, target.deletingLastPathComponent().path, "checked next to the app, not where it was downloaded")
        XCTAssertEqual(discarded, [".Maben Base.old.app 0.2"])
        XCTAssertEqual(Updater.version(of: target), "0.3")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
        XCTAssertEqual(Updater.version(of: new), "0.3", "the source is copied, not moved")
    }

    /// The real check passes on the copy under its hidden name next to the app.
    func testSwapInstallsARealReleaseCheckedWhereItLands() throws {
        let release = try installedRelease()
        let version = try XCTUnwrap(Updater.version(of: release))
        let target = try makeApp("Apps/Maben Base.app", version: "0.0.1")
        try Updater.replace(target, with: release, version: version, askForPassword: false,
                            check: { try Updater.verify($0, expectedVersion: version) }, discard: remove)
        XCTAssertEqual(Updater.version(of: target), version)
        XCTAssertTrue(CodeSignature.satisfies(target, Updater.requirement()))
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testSwapLeavesTheAppAloneWhenTheCopyFailsTheCheck() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        var discarded = 0
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in throw Updater.Failure("not ours") }, discard: { _ in discarded += 1 })) {
            XCTAssertEqual(($0 as? Updater.Failure)?.message, "not ours")
        }
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(discarded, 0)
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"], "the copy that failed is removed")
    }

    /// The real check on a stand-in that isn't signed: it never gets in.
    func testSwapRefusesAnAppThatIsNotOurs() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        XCTAssertThrowsError(try Updater.replace(target, with: new, version: "0.3", askForPassword: false,
                                                 check: { try Updater.verify($0, expectedVersion: "0.3") }, discard: remove))
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testSwapPutsTheOldAppBackWhenTheNewOneCantMoveIn() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        var moves = 0, discarded = 0
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in }, move: { from, to in
            moves += 1
            if moves == 2 { throw CocoaError(.fileWriteNoPermission) }   // the new app moving into place
            try FileManager.default.moveItem(at: from, to: to)
        }, discard: { _ in discarded += 1 }))
        XCTAssertEqual(moves, 3, "out, in (fails), back")
        XCTAssertEqual(discarded, 0, "the old app is the app again, not on its way to the Trash")
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testSwapLeavesTheAppAloneWhenItCantBeMovedAside() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        XCTAssertThrowsError(try Updater.swap(target, with: new, check: { _ in }, move: { _, _ in throw CocoaError(.fileWriteNoPermission) }, discard: remove))
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testSwapReplacesWhatAnEarlierSwapLeftBehind() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        try makeApp("Apps/.Maben Base.update.app", version: "0.0.1")
        try makeApp("Apps/.Maben Base.old.app", version: "0.0.2")
        try Updater.swap(target, with: new, check: { XCTAssertEqual(Updater.version(of: $0), "0.3") }, discard: { old in
            XCTAssertEqual(Updater.version(of: old), "0.2", "the app that was just replaced, not the leftover")
            self.remove(old)
        })
        XCTAssertEqual(Updater.version(of: target), "0.3")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testLeftoversOfACutShortSwapAreRemovedAtLaunch() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.3")
        try makeApp("Apps/.Maben Base.update.app", version: "0.4")
        try makeApp("Apps/.Maben Base.old.app", version: "0.2")
        try makeApp("Apps/Other.app", version: "1")
        Updater.removeLeftovers(beside: target)
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app", "Other.app"])
    }

    func testReplaceWithoutPasswordFailsOnAReadOnlyFolder() throws {
        let target = try makeApp("Locked/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        let folder = target.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try Updater.replace(target, with: new, version: "0.3", askForPassword: false, check: { _ in }, discard: remove))
        XCTAssertEqual(Updater.version(of: target), "0.2", "the running app is left alone")
    }

    // MARK: Installing as root

    func testRootInstallCommandCopiesChecksThenSwaps() {
        let command = Updater.rootInstallCommand(newApp: "/tmp/Update/Maben Base.app", target: "/Applications/Maben Base.app",
                                                 requirement: Updater.requirement(), version: "0.3", token: "TOKEN")
        XCTAssertEqual(command, """
        T='/Applications/Maben Base.app'
        D='/Applications/.Maben Base.update.TOKEN'
        S="$D/Maben Base.app"
        fail() { /bin/rm -rf "$D"; exit 1; }
        /bin/mkdir -m 700 "$D" || exit 1
        /usr/bin/ditto '/tmp/Update/Maben Base.app' "$S" || fail
        /usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail
        /bin/chmod -R ug-s "$S" || fail
        /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "NJTYRVLSA8" and (identifier "gg.maben.base") and notarized' "$S" || fail
        /usr/sbin/spctl --assess --type execute "$S" || fail
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = '0.3' ] || fail
        /bin/mv "$T" "$D/old.app" || fail
        /bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" || exit 1; fail; }
        /bin/rm -rf "$D"
        exit 0
        """)
    }

    func testRootInstallCommandQuotesEverythingItIsGiven() {
        let command = Updater.rootInstallCommand(newApp: "/tmp/it's $(id) `id` \"x\"/New.app", target: "/Apps/O'Brien; id/Maben Base.app",
                                                 requirement: "identifier \"a\" and 'b'", version: "1'; id; '", token: "t'; id")
        XCTAssertTrue(command.contains(#"/usr/bin/ditto '/tmp/it'\''s $(id) `id` "x"/New.app' "$S""#))
        XCTAssertTrue(command.contains(#"T='/Apps/O'\''Brien; id/Maben Base.app'"#))
        XCTAssertTrue(command.contains(#"D='/Apps/O'\''Brien; id/.Maben Base.update.t'\''; id'"#))
        XCTAssertTrue(command.contains(#"-R='identifier "a" and '\''b'\''' "$S""#))
        XCTAssertTrue(command.contains(#"= '1'\''; id; '\''' ]"#))
    }

    /// The command goes to root inside AppleScript source: a quote or backslash in it stays inside the string.
    func testTheAdminScriptKeepsTheCommandInsideItsString() {
        XCTAssertEqual(AdminShell.source("echo \"a\\b\"\nexit 0", prompt: "Say \"yes\""),
                       #"do shell script "echo \"a\\b\"\nexit 0" with prompt "Say \"yes\"" with administrator privileges"#)
        XCTAssertEqual(AdminShell.quote("it's"), #"'it'\''s'"#)
    }

    private func sh(_ command: String) -> Int32 { Updater.run("/bin/sh", ["-c", command]) }

    /// The command itself, run without root in a folder of our own: an app that isn't ours never gets in,
    /// and nothing is left behind.
    func testRootInstallCommandLeavesTheAppAloneWhenTheCopyIsNotOurs() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        let command = Updater.rootInstallCommand(newApp: new.path, target: target.path, requirement: Updater.requirement(), version: "0.3", token: "T1")
        XCTAssertNotEqual(sh(command), 0)
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), ["Maben Base.app"])
    }

    func testRootInstallCommandStopsWhenItsFolderAlreadyExists() throws {
        let target = try makeApp("Apps/Maben Base.app", version: "0.2"), new = try makeApp("New/Maben Base.app", version: "0.3")
        let planted = target.deletingLastPathComponent().appendingPathComponent(".Maben Base.update.T2")
        try fm.createDirectory(at: planted, withIntermediateDirectories: true)
        let command = Updater.rootInstallCommand(newApp: new.path, target: target.path, requirement: Updater.requirement(), version: "0.3", token: "T2")
        XCTAssertNotEqual(sh(command), 0)
        XCTAssertEqual(Updater.version(of: target), "0.2")
        XCTAssertEqual(try names(in: target.deletingLastPathComponent()), [".Maben Base.update.T2", "Maben Base.app"], "a folder that was already there is not used and not removed")
    }

    /// The whole command with a real release, as far as it goes without root: checked, swapped, cleaned up.
    func testRootInstallCommandInstallsARealRelease() throws {
        let release = try installedRelease()
        let version = try XCTUnwrap(Updater.version(of: release))
        let target = try makeApp("Apps/Maben Base.app", version: "0.0.1")
        let folder = target.deletingLastPathComponent()

        let wrong = Updater.rootInstallCommand(newApp: release.path, target: target.path, requirement: Updater.requirement(), version: version + ".1", token: "T3")
        XCTAssertNotEqual(sh(wrong), 0, "the right app under the wrong version")
        XCTAssertEqual(Updater.version(of: target), "0.0.1")
        XCTAssertEqual(try names(in: folder), ["Maben Base.app"])

        let other = Updater.rootInstallCommand(newApp: release.path, target: target.path, requirement: Updater.requirement(identifiers: ["gg.maben.other"]), version: version, token: "T4")
        XCTAssertNotEqual(sh(other), 0, "the right app under another bundle ID")
        XCTAssertEqual(Updater.version(of: target), "0.0.1")

        let right = Updater.rootInstallCommand(newApp: release.path, target: target.path, requirement: Updater.requirement(), version: version, token: "T5")
        XCTAssertEqual(sh(right), 0)
        XCTAssertEqual(Updater.version(of: target), version)
        XCTAssertTrue(CodeSignature.satisfies(target, Updater.requirement()))
        XCTAssertEqual(try names(in: folder), ["Maben Base.app"])
    }
}
