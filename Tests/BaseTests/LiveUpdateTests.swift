@testable import Base
import BaseCore
import XCTest

/// The whole update against the release GitHub serves today: the feed, the download, unpacking, the checks
/// and the swap, into a folder made for the test. It needs the network, so it only runs with MABEN_LIVE=1.
final class LiveUpdateTests: XCTestCase {
    func testTheLatestReleaseInstallsOverAnOlderCopy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MABEN_LIVE"] == "1", "set MABEN_LIVE=1 to run against GitHub")
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("maben-live-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let release = try XCTUnwrap(ReleaseFeed.parse(try Data(contentsOf: ReleaseFeed.url)), "the answer GitHub gives today isn't accepted as a release")
        let zip = work.appendingPathComponent("update.zip")
        try Data(contentsOf: release.zip).write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        XCTAssertEqual(run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]), 0)
        let newApp = try XCTUnwrap(try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first { $0.pathExtension == "app" })

        // An older copy stands where the app is installed.
        let target = work.appendingPathComponent("Apps/\(newApp.lastPathComponent)")
        try fm.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("Contents/old"))

        // The app's own checks, on the copy where it lands.
        try Updater.verify(newApp, expectedVersion: release.version)
        try Updater.swap(target, with: newApp, check: { try Updater.verify($0, expectedVersion: release.version) },
                         discard: { try? fm.removeItem(at: $0) })

        let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, release.version)
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Contents/old").path), "the older copy is gone")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), [target.lastPathComponent], "nothing is left beside the app")
        XCTAssertEqual(run("/usr/sbin/spctl", ["--assess", "--type", "execute", target.path]), 0, "what was installed opens without a warning")
    }

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
