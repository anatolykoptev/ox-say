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
        XCTAssertTrue(body.contains("recordingMeeting: meetings?.isRecording"), "appWork() does not report whether a meeting is recording")
    }

    /// A design in progress holds the version handshake: appWork() reads `studio.designing`, which is the designer's
    /// `running`, which is the flow's `isBusy` (designing, reviewing or saving).
    /// Mutation: AppDelegate.appWork(), `designing: studio.designing` -> `designing: false` -> RED; so is
    /// VoiceDesigner.running returning `false`, or StudioController.designing not reading the designer.
    func testDesignInProgressHoldsTheHandshake() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation")
        func text(_ name: String) throws -> String {
            MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
        let app = try text("AppDelegate.swift")
        let start = try XCTUnwrap(app.range(of: "private func appWork() -> VersionHandshake.AppWork {"))
        let end = try XCTUnwrap(app.range(of: "\n    }\n", range: start.upperBound..<app.endIndex))
        XCTAssertTrue(app[start.lowerBound..<end.upperBound].contains("designing: studio.designing,"),
                      "appWork() does not report a voice design in progress")
        let controller = try text("StudioController.swift")
        let designer = try text("VoiceDesigner.swift")
        XCTAssertTrue(controller.contains("var designing: Bool { designer.running }"))
        XCTAssertTrue(designer.contains("var running: Bool { flow.isBusy }"))
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: true, followingVoiceover: false,
                                               recordingMeeting: false).idle == false)
    }
}
