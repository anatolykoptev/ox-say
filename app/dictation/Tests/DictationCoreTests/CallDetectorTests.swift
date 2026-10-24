import Foundation
import XCTest
@testable import DictationCore

final class CallDetectorTests: XCTestCase {
    private func src(_ users: [MicUser], url: String? = nil) -> String? {
        CallDetector.source(of: users, activeURL: { _ in url })
    }

    func testZoomOnTheMicrophoneIsACall() {
        XCTAssertEqual(src([MicUser(bundleID: "us.zoom.xos", pid: 10)]), "zoom")
    }

    /// Dictation, a voice memo, any app outside the allowlist never starts a recording.
    /// Mutation: CallDetector.source, change `if id == ownBundleID { continue }` to
    /// `if false { continue }` and put ox-say's bundle id in `nativeApps` -> RED.
    func testOurOwnDictationAndUnknownAppsAreNotCalls() {
        XCTAssertNil(src([MicUser(bundleID: CallDetector.ownBundleID, pid: 1)]))
        XCTAssertNil(src([MicUser(bundleID: "com.apple.VoiceMemos", pid: 2)]))
        XCTAssertNil(src([]))
    }

    /// A browser on the microphone is a call only when its tab is a meeting page.
    /// Mutation: CallDetector.source, drop the `MeetingURL.source` check (return "browser")
    /// -> RED (a video site using the microphone starts a recording).
    func testBrowserNeedsAMeetingPage() {
        let chrome = [MicUser(bundleID: "com.google.Chrome.helper.Renderer", pid: 3)]
        XCTAssertEqual(src(chrome, url: "https://meet.google.com/abc-defg-hij"), "meet")
        XCTAssertNil(src(chrome, url: "https://www.youtube.com/watch?v=1"))
        XCTAssertNil(src(chrome, url: nil), "an unreadable tab is not a call")
    }

    func testTheBrowserIsOnlyAskedWhenItHoldsTheMicrophone() {
        var asked: [String] = []
        _ = CallDetector.source(of: [MicUser(bundleID: "com.apple.VoiceMemos", pid: 2)], activeURL: { asked.append($0); return nil })
        XCTAssertEqual(asked, [])
    }

    /// The call's browser keeps the call alive when the user switches tabs; the
    /// matcher reports which bundle holds it.
    func testMatchNamesTheBundleAndHoldsSurvivesATabSwitch() throws {
        let chrome = [MicUser(bundleID: "com.google.Chrome.helper", pid: 3)]
        let found = try XCTUnwrap(CallDetector.match(of: chrome, activeURL: { _ in "https://meet.google.com/abc-defg-hij" }))
        XCTAssertEqual(found.source, "meet")
        XCTAssertEqual(found.bundleID, "com.google.Chrome")
        XCTAssertNil(CallDetector.source(of: chrome, activeURL: { _ in "https://news.example.com" }), "another tab in front is no call to detect")
        XCTAssertTrue(CallDetector.holds(chrome, bundleID: found.bundleID), "but the browser still holds the microphone")
        XCTAssertFalse(CallDetector.holds([], bundleID: found.bundleID))
    }

    /// Discord and FaceTime are offered, not started by themselves.
    /// Mutation: CallDetector.autoStartSources, add "discord" -> RED.
    func testOnlyWorkCallAppsStartByThemselves() {
        XCTAssertTrue(CallDetector.autoStartSources.isSuperset(of: ["zoom", "teams", "webex", "meet"]))
        for source in ["discord", "facetime", "slack"] { XCTAssertFalse(CallDetector.autoStartSources.contains(source), source) }
        XCTAssertEqual(Set(CallDetector.nativeApps.values).subtracting(CallDetector.autoStartSources), ["slack", "facetime", "discord"])
    }

    func testMeetingURLs() {
        XCTAssertEqual(MeetingURL.source(of: "https://meet.google.com/abc-defg-hij?authuser=0"), "meet")
        XCTAssertNil(MeetingURL.source(of: "https://meet.google.com/landing"))
        XCTAssertNil(MeetingURL.source(of: "https://meet.google.com/"))
        XCTAssertEqual(MeetingURL.source(of: "https://us02web.zoom.us/wc/join/123"), "zoom")
        XCTAssertEqual(MeetingURL.source(of: "https://acme.zoom.us/j/123"), "zoom")
        XCTAssertNil(MeetingURL.source(of: "https://zoom.us/pricing"))
        XCTAssertEqual(MeetingURL.source(of: "https://teams.microsoft.com/l/meetup-join/19%3a"), "teams")
        XCTAssertNil(MeetingURL.source(of: "not a url"))
    }

    // MARK: tracker

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testACallIsAnnouncedOnceAfterTheDebounce() {
        var tr = CallTracker()
        XCTAssertEqual(tr.observe(now: t0, call: "zoom", themActive: false, recording: nil), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(3), call: "zoom", themActive: false, recording: nil), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(4), call: "zoom", themActive: false, recording: nil), .callStarted(source: "zoom"))
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(6), call: "zoom", themActive: false, recording: nil), .nothing, "announced once")
    }

    /// "Don't record this one" holds until the call is over.
    /// Mutation: CallTracker.observe, delete `!declined` from the announce condition -> RED.
    func testADeclinedCallIsNotOfferedAgain() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: "meet", themActive: false, recording: nil)
        tr.decline()
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(10), call: "meet", themActive: false, recording: nil), .nothing)
        // the call ends (30 s with no call app), then a new one comes
        _ = tr.observe(now: t0.addingTimeInterval(20), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(55), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(60), call: "meet", themActive: false, recording: nil)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(65), call: "meet", themActive: false, recording: nil), .callStarted(source: "meet"))
    }

    /// A brief mic release (a mute) does not end the recording; only 30 s with
    /// no call app and a silent far side does.
    /// Mutation: CallTracker.observe, change `if themActive {` to `if false {` -> RED
    /// (a muted listener loses the rest of the call).
    func testTheRecordingStopsOnlyWhenTheCallAndTheFarSideAreBothQuiet() {
        var tr = CallTracker()
        XCTAssertEqual(tr.observe(now: t0, call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(29), call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(30), call: nil, themActive: false, recording: .auto), .stopRecording)

        var heard = CallTracker()
        for s in stride(from: 0.0, through: 120.0, by: 5.0) {
            XCTAssertEqual(heard.observe(now: t0.addingTimeInterval(s), call: nil, themActive: true, recording: .auto), .nothing,
                           "the other side is still talking at \(s) s")
        }
    }

    func testAMicBlipResetsTheEndTimer() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: nil, themActive: false, recording: .auto)
        _ = tr.observe(now: t0.addingTimeInterval(25), call: "meet", themActive: false, recording: .auto)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(40), call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(70), call: nil, themActive: false, recording: .auto), .stopRecording)
    }

    /// A recording the user started by hand is never stopped for them.
    /// Mutation: CallTracker.observe, change `case .auto:` to `case .auto, .manual:` and delete the
    /// `case .manual:` block -> RED.
    func testAManualRecordingIsNeverAutoStopped() {
        var tr = CallTracker()
        for s in stride(from: 0.0, through: 600.0, by: 10.0) {
            XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(s), call: nil, themActive: false, recording: .manual), .nothing)
        }
    }
}
