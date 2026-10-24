import Foundation
import XCTest
@testable import DictationCore

final class AppWorkMeetingTests: XCTestCase {
    /// A relaunch or a daemon restart never fires under a recording.
    /// Mutation: VersionHandshake.AppWork.idle, drop `|| recordingMeeting` -> RED.
    func testRecordingAMeetingIsWork() {
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false, recordingMeeting: false).idle)
        XCTAssertFalse(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                                recordingMeeting: true).idle)
    }

    /// The relaunch guard is inert unless AppDelegate says whether a meeting is
    /// recording: the constructor has no default, and appWork() must pass the
    /// argument (Task 17 replaces the `false` with the live state).
    /// Mutation: AppDelegate.appWork(), delete the `recordingMeeting:` argument -> RED
    /// (the shim compiles DictationCore only, so the source read is what catches it).
    func testAppWorkNamesTheRecordingState() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        guard let start = source.range(of: "private func appWork() -> VersionHandshake.AppWork {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return XCTFail("appWork() not found") }
        let body = source[start.lowerBound..<end.upperBound]
        XCTAssertTrue(body.contains("recordingMeeting:"), "appWork() does not report whether a meeting is recording")
    }
}
