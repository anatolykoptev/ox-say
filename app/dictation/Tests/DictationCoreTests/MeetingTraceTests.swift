import XCTest
@testable import DictationCore

/// Every prompt/recording transition is logged under `meeting` (#518), with no private data: the app name, never a
/// window title or a URL.
final class MeetingTraceTests: XCTestCase {
    func testEveryEventHasAStableLine() {
        let table: [(MeetingTrace.Event, String)] = [
            (.promptShown(app: "Google Meet"), "prompt shown app=Google Meet"),
            (.answered(.record, app: "Google Meet"), "prompt answered choice=record app=Google Meet"),
            (.answered(.notNow, app: "Zoom"), "prompt answered choice=not_now app=Zoom"),
            (.answered(.dontAsk, app: "Zoom"), "prompt answered choice=dont_ask app=Zoom"),
            (.answered(.cancel, app: "Zoom"), "prompt answered choice=cancel app=Zoom"),
            (.checking(holder: "browser"), "record check holder=browser"),
            (.checked(.record, stale: false, tabs: "call_page"), "record check verdict=record stale=false tabs=call_page"),
            (.checked(.ask, stale: true, tabs: "unknown"), "record check verdict=ask stale=true tabs=unknown"),
            (.checkSuperseded, "record check superseded"),
            (.autoStarting(app: "Zoom"), "auto record app=Zoom"),
            (.autoIgnored(app: "Zoom", reason: "mode_never"), "call ignored app=Zoom reason=mode_never"),
            (.startRequested(origin: "manual", offered: false, app: "manual"), "start requested origin=manual offered=false app=manual"),
            (.startRefused(reason: "already_starting"), "start refused reason=already_starting"),
            (.started(id: "m1", origin: "auto"), "started id=m1 origin=auto"),
            (.startFailed(reason: "mic_permission"), "start failed reason=mic_permission"),
            (.stopped(id: "m1", why: "user"), "stopped id=m1 why=user"),
        ]
        for (event, line) in table { XCTAssertEqual(event.line, line) }
    }

    /// Mutation: MeetingTrace.Event.line, interpolate the free text of `reason` without `sanitized` -> RED.
    func testFreeTextIsReducedToATokenSoNoTitleOrUrlGetsIn() {
        let line = MeetingTrace.Event.startFailed(reason: "Standup — https://meet.google.com/abc-defg-hij (Brave)").line
        XCTAssertFalse(line.contains("http"))
        XCTAssertFalse(line.contains("Standup"))
        XCTAssertFalse(line.contains(" ("))
        XCTAssertEqual(MeetingTrace.sanitized("Mic denied: no_permission"), "mic_denied_no_permission")
        XCTAssertEqual(MeetingTrace.sanitized(""), "unknown")
    }

    func testStartFailureReasonForAnErrorIsItsTypeNotItsText() {
        struct Boom: Error, CustomStringConvertible { var description: String { "secret title https://x" } }
        XCTAssertEqual(MeetingTrace.reason(of: Boom()), "boom")
    }
}
