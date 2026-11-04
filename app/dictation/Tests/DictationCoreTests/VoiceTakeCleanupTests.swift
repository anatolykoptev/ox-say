import Foundation
import XCTest
@testable import DictationCore

/// The launch sweep of leftover take folders («Записать свой голос» writes into a private `ox-say-voice-<uuid>`
/// temp folder that a crash leaves behind). Named matches only, real directories only, a symlink never followed.
final class VoiceTakeCleanupTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTemp() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("ox-say-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A leftover take folder goes; a stranger's folder, a same-named FILE and a symlinked directory all stay.
    /// Mutation: VoiceTakeCleanup.swift `isTakeFolder` -> `true` -> RED (it would remove a stranger's folder);
    /// the `.typeDirectory` check dropped -> RED (the file and the link's target would be judged ours).
    func testTheSweepRemovesOnlyRealTakeFolders() throws {
        let root = try makeTemp()
        defer { try? fm.removeItem(at: root) }
        let take = root.appendingPathComponent("ox-say-voice-\(UUID().uuidString)")
        try fm.createDirectory(at: take, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: take.appendingPathComponent("voice.wav"))
        let keep = root.appendingPathComponent("keep-me")
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)
        // A file whose name matches is not a folder we made.
        try Data("x".utf8).write(to: root.appendingPathComponent("ox-say-voice-not-a-dir"))
        // A symlink named like a take folder must not be followed into the stranger's directory.
        let stranger = root.appendingPathComponent("stranger")
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)
        let inside = stranger.appendingPathComponent("inner.txt")
        try Data("y".utf8).write(to: inside)
        let link = root.appendingPathComponent("ox-say-voice-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: stranger)

        XCTAssertEqual(VoiceTakeCleanup.sweep(in: root), 1)
        XCTAssertFalse(fm.fileExists(atPath: take.path), "the leftover take folder is gone")
        XCTAssertTrue(fm.fileExists(atPath: keep.path), "a stranger's folder stays")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ox-say-voice-not-a-dir").path),
                      "a same-named file stays")
        XCTAssertTrue(fm.fileExists(atPath: inside.path), "the link's target is untouched")
        var isLink: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: link.path, isDirectory: &isLink), "the link itself stays too")
        XCTAssertEqual(VoiceTakeCleanup.sweep(in: root), 0, "a second pass finds nothing")
    }

    /// The name rule: the prefix plus anything — nothing else is the app's to touch.
    func testIsTakeFolderNamesOnly() {
        XCTAssertTrue(VoiceTakeCleanup.isTakeFolder("ox-say-voice-\(UUID().uuidString)"))
        XCTAssertFalse(VoiceTakeCleanup.isTakeFolder("ox-say-voice-"))
        XCTAssertFalse(VoiceTakeCleanup.isTakeFolder("ox-say-voice"))
        XCTAssertFalse(VoiceTakeCleanup.isTakeFolder("keep-me"))
        XCTAssertFalse(VoiceTakeCleanup.isTakeFolder("x-ox-say-voice-1"))
    }

    /// The sweep runs at launch, not on first use: a leftover is gone before a sheet can open. PIN (source text).
    /// Mutation: AppDelegate.swift the `VoiceTakeCleanup.sweep` call deleted -> RED.
    func testTheSweepRunsAtLaunch() throws {
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(app.range(of: "func applicationWillTerminate", range: launch.upperBound..<app.endIndex))
        let body = String(app[launch.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("VoiceTakeCleanup.sweep(in: FileManager.default.temporaryDirectory)"), body.prefix(200).description)
    }
}
