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

    /// The classic Teams link keeps its route in the fragment; the path must be a join
    /// or meet route, not any page that mentions "meet".
    func testTeamsAndZoomgovURLs() {
        XCTAssertEqual(MeetingURL.source(of: "https://teams.microsoft.com/_#/l/meetup-join/19%3ameeting_x/0?context=%7b%7d"), "teams")
        XCTAssertEqual(MeetingURL.source(of: "https://teams.microsoft.com/l/meetup-join/19%3a"), "teams")
        XCTAssertEqual(MeetingURL.source(of: "https://teams.live.com/meet/9876543210"), "teams")
        XCTAssertNil(MeetingURL.source(of: "https://teams.microsoft.com/_#/conversations/General"))
        XCTAssertNil(MeetingURL.source(of: "https://teams.microsoft.com/meetings-calendar"))
        XCTAssertNil(MeetingURL.source(of: "https://teams.microsoft.com/_#/calendarv2?q=meetup-join"))
        XCTAssertEqual(MeetingURL.source(of: "https://us06web.zoomgov.com/j/123"), "zoom")
        XCTAssertEqual(MeetingURL.source(of: "https://acme.zoomgov.com/wc/join/1"), "zoom")
        XCTAssertNil(MeetingURL.source(of: "https://www.zoomgov.com/pricing"))
    }

    func testCanonicalStripsOnlyAHelperComponent() {
        XCTAssertEqual(CallDetector.canonical("com.google.Chrome.helper.Renderer"), "com.google.Chrome")
        XCTAssertEqual(CallDetector.canonical("com.brave.Browser.helper"), "com.brave.Browser")
        XCTAssertEqual(CallDetector.canonical("com.acme.helperapp"), "com.acme.helperapp")
        XCTAssertEqual(CallDetector.canonical("us.zoom.xos"), "us.zoom.xos")
    }

    // MARK: detection

    /// Two calls at once: the one that starts a recording by itself wins, whatever the
    /// order of the process list.
    /// Mutation: CallDetector.detect, replace the `best` selection with `found.first` -> RED.
    func testAnAutoStartCallWinsInEitherOrder() {
        let slack = MicUser(bundleID: "com.tinyspeck.slackmacgap", pid: 1)
        let zoom = MicUser(bundleID: "us.zoom.xos", pid: 2)
        XCTAssertEqual(src([slack, zoom]), "zoom")
        XCTAssertEqual(src([zoom, slack]), "zoom")
        let chrome = MicUser(bundleID: "com.google.Chrome.helper", pid: 3)
        XCTAssertEqual(CallDetector.detect(of: [slack, chrome], tab: { _ in .url("https://meet.google.com/abc-defg-hij") }).call?.source, "meet")
        XCTAssertEqual(CallDetector.detect(of: [chrome, slack], tab: { _ in .url("https://meet.google.com/abc-defg-hij") }).call?.source, "meet")
        // two of a kind: a stable pick (lowest bundle id)
        let teams = MicUser(bundleID: "com.microsoft.teams2", pid: 4)
        XCTAssertEqual(src([zoom, teams]), src([teams, zoom]))
    }

    /// A browser that denies Automation must not look like "no call".
    /// Mutation: CallDetector.detect, replace `case .denied: denied = true` with `case .denied: break` -> RED.
    func testADeniedBrowserIsDistinguishableFromNoCall() {
        let chrome = [MicUser(bundleID: "com.google.Chrome.helper", pid: 3)]
        let denied = CallDetector.detect(of: chrome, tab: { _ in .denied })
        XCTAssertNil(denied.call)
        XCTAssertTrue(denied.browserDenied)
        let tabless = CallDetector.detect(of: chrome, tab: { _ in .unreadable })
        XCTAssertFalse(tabless.browserDenied)
        XCTAssertTrue(tabless.browserUnreadable)
        let other = CallDetector.detect(of: chrome, tab: { _ in .url("https://news.example.com") })
        XCTAssertEqual(other, CallDetector.Detection())
        // a native call in progress makes a denied browser beside it beside the point
        let zoom = MicUser(bundleID: "us.zoom.xos", pid: 1)
        XCTAssertFalse(CallDetector.detect(of: chrome + [zoom], tab: { _ in .denied }).browserDenied)
        XCTAssertEqual(CallDetector.detect(of: [zoom], tab: { _ in .denied }).call?.source, "zoom")
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
        // the call ends (90 s with no call app), then a new one comes
        _ = tr.observe(now: t0.addingTimeInterval(20), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(115), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(120), call: "meet", themActive: false, recording: nil)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(125), call: "meet", themActive: false, recording: nil), .callStarted(source: "meet"))
    }

    /// A brief mic release (a mute) does not end the recording; only 90 s with
    /// no call app and a silent far side does.
    /// Mutation: CallTracker.observe, change `if themActive {` to `if false {` -> RED
    /// (a muted listener loses the rest of the call).
    func testTheRecordingStopsOnlyWhenTheCallAndTheFarSideAreBothQuiet() {
        var tr = CallTracker()
        XCTAssertEqual(tr.observe(now: t0, call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(89), call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(90), call: nil, themActive: false, recording: .auto), .stopRecording)

        var heard = CallTracker()
        for s in stride(from: 0.0, through: 120.0, by: 5.0) {
            XCTAssertEqual(heard.observe(now: t0.addingTimeInterval(s), call: nil, themActive: true, recording: .auto), .nothing,
                           "the other side is still talking at \(s) s")
        }
    }

    func testAMicBlipResetsTheEndTimer() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: nil, themActive: false, recording: .auto)
        _ = tr.observe(now: t0.addingTimeInterval(80), call: "meet", themActive: false, recording: .auto)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(100), call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(189), call: nil, themActive: false, recording: .auto), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(190), call: nil, themActive: false, recording: .auto), .stopRecording)
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

    /// A recording the user started during a call, then stopped, stays stopped for the rest of that call.
    /// Mutation: CallTracker.observe, delete `announced = true` in the `if recording != nil` block -> RED.
    func testAUserStopStaysStoppedWhileTheCallContinues() {
        var tr = CallTracker()
        for s in stride(from: 0.0, through: 600.0, by: 10.0) {
            XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(s), call: "zoom", themActive: true, recording: .manual), .nothing)
        }
        for s in stride(from: 601.0, through: 700.0, by: 3.0) {
            XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(s), call: "zoom", themActive: true, recording: nil), .nothing, "at \(s) s")
        }
        // the call ends for good, a new one is offered again
        _ = tr.observe(now: t0.addingTimeInterval(710), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(810), call: nil, themActive: false, recording: nil)
        _ = tr.observe(now: t0.addingTimeInterval(820), call: "zoom", themActive: false, recording: nil)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(824), call: "zoom", themActive: false, recording: nil), .callStarted(source: "zoom"))
    }

    func testStoppingAnAutoRecordingByHandAlsoStaysStopped() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: "zoom", themActive: true, recording: nil)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(4), call: "zoom", themActive: true, recording: nil), .callStarted(source: "zoom"))
        _ = tr.observe(now: t0.addingTimeInterval(6), call: "zoom", themActive: true, recording: .auto)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(60), call: "zoom", themActive: true, recording: nil), .nothing)
    }

    /// An automatic stop (a muted listener, a long silence) does not end the call:
    /// when the far side comes back the call is offered again.
    /// Mutation: CallTracker.observe, delete `announced = false` before `return .stopRecording` -> RED.
    func testAnAutoStopRearmsTheEpisode() {
        for comeBack in [2.0, 60.0] {
            var tr = CallTracker()
            _ = tr.observe(now: t0, call: "zoom", themActive: true, recording: nil)
            XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(4), call: "zoom", themActive: true, recording: nil), .callStarted(source: "zoom"))
            _ = tr.observe(now: t0.addingTimeInterval(10), call: nil, themActive: false, recording: .auto)
            let stop = t0.addingTimeInterval(10 + CallTracker.endAfter)
            XCTAssertEqual(tr.observe(now: stop, call: nil, themActive: false, recording: .auto), .stopRecording)
            XCTAssertEqual(tr.observe(now: stop.addingTimeInterval(comeBack), call: "zoom", themActive: true, recording: nil), .nothing)
            XCTAssertEqual(tr.observe(now: stop.addingTimeInterval(comeBack + 3), call: "zoom", themActive: true, recording: nil), .nothing)
            XCTAssertEqual(tr.observe(now: stop.addingTimeInterval(comeBack + 4), call: "zoom", themActive: true, recording: nil),
                           .callStarted(source: "zoom"), "back after \(comeBack) s")
        }
    }

    func testGroupCallSilenceUnderNinetySecondsDoesNotStop() {
        XCTAssertEqual(CallTracker.endAfter, 90)
    }

    /// A call in another app is a new call: a decline or an earlier announcement does not carry over.
    /// Mutation: CallTracker.observe, delete the `if let episode, episode != key {…}` block -> RED.
    func testACallInAnotherAppIsANewEpisode() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: "meet", themActive: false, recording: nil, bundleID: "com.google.Chrome")
        tr.decline()
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(10), call: "meet", themActive: false, recording: nil, bundleID: "com.google.Chrome"), .nothing)
        _ = tr.observe(now: t0.addingTimeInterval(12), call: "zoom", themActive: false, recording: nil, bundleID: "us.zoom.xos")
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(16), call: "zoom", themActive: false, recording: nil, bundleID: "us.zoom.xos"), .callStarted(source: "zoom"))
        // announced meet, then the same source in another browser
        var other = CallTracker()
        _ = other.observe(now: t0, call: "meet", themActive: false, recording: nil, bundleID: "com.google.Chrome")
        XCTAssertEqual(other.observe(now: t0.addingTimeInterval(4), call: "meet", themActive: false, recording: nil, bundleID: "com.google.Chrome"), .callStarted(source: "meet"))
        _ = other.observe(now: t0.addingTimeInterval(6), call: "meet", themActive: false, recording: nil, bundleID: "com.brave.Browser")
        XCTAssertEqual(other.observe(now: t0.addingTimeInterval(10), call: "meet", themActive: false, recording: nil, bundleID: "com.brave.Browser"), .callStarted(source: "meet"))
    }

    /// One tick where a browser held the microphone but its tab could not be read is not a hang-up.
    /// Mutation: CallTracker.observe, delete the `if callUnreadable, … { … return .nothing }` block -> RED.
    func testOneUnreadableTickKeepsTheDebounce() {
        var tr = CallTracker()
        _ = tr.observe(now: t0, call: "meet", themActive: false, recording: nil)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(2), call: nil, themActive: false, recording: nil, callUnreadable: true), .nothing)
        XCTAssertEqual(tr.observe(now: t0.addingTimeInterval(4), call: "meet", themActive: false, recording: nil), .callStarted(source: "meet"))

        // a second unreadable tick in a row does break it
        var two = CallTracker()
        _ = two.observe(now: t0, call: "meet", themActive: false, recording: nil)
        _ = two.observe(now: t0.addingTimeInterval(1), call: nil, themActive: false, recording: nil, callUnreadable: true)
        _ = two.observe(now: t0.addingTimeInterval(2), call: nil, themActive: false, recording: nil, callUnreadable: true)
        XCTAssertEqual(two.observe(now: t0.addingTimeInterval(4), call: "meet", themActive: false, recording: nil), .nothing)
    }

    // MARK: watch

    private static let meetURL = "https://meet.google.com/abc-defg-hij"
    private let chromeOnMic = [MicUser(bundleID: "com.google.Chrome.helper", pid: 3)]

    /// One polling round of a browser call: Chrome holds the microphone, `url`
    /// is what its front tab reads as ("" = unreadable).
    private func watchTick(_ watch: inout CallWatch, now: Date, users: [MicUser]? = nil, url: String,
                           recording: CallTracker.Origin? = nil) -> CallWatch.Outcome {
        watch.observe(now: now, users: users ?? chromeOnMic,
                      tab: { _ in url.isEmpty ? .unreadable : .url(url) },
                      themActive: false, recording: recording)
    }

    /// Issue #241's repro: the user stops a browser-call recording, keeps another
    /// tab in front past the idle timeout, then returns to the Meet tab — all while
    /// the browser never lets go of the microphone. The stop still stands.
    /// Mutation: CallWatch.observe, delete the `if call == nil, let last = lastCall, …` block -> RED.
    func testAUserStopSurvivesLeavingTheCallTab() {
        var watch = CallWatch()
        _ = watchTick(&watch, now: t0, url: Self.meetURL)
        // the user records by hand for a while, then stops — a user stop
        _ = watchTick(&watch, now: t0.addingTimeInterval(10), url: Self.meetURL, recording: .manual)
        _ = watchTick(&watch, now: t0.addingTimeInterval(20), url: Self.meetURL)
        // two minutes on another tab; the browser still holds the microphone
        let outcome = watchTick(&watch, now: t0.addingTimeInterval(30), url: "")
        XCTAssertEqual(outcome.call?.source, "meet", "the call goes on while the browser holds the mic")
        XCTAssertEqual(outcome.call?.bundleID, "com.google.Chrome")
        _ = watchTick(&watch, now: t0.addingTimeInterval(130), url: "")
        // back on the Meet tab: the stop still stands, no second offer
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(140), url: Self.meetURL).action, .nothing)
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(145), url: Self.meetURL).action, .nothing)
    }

    /// "Don't record this one" stands while the browser call goes on in another tab.
    /// Mutation: CallWatch.observe, delete the holds-fallback -> RED (the idle reset
    /// clears `declined` and the call is offered again).
    func testADeclinedCallSurvivesATabSwitch() {
        var watch = CallWatch()
        _ = watchTick(&watch, now: t0, url: Self.meetURL)
        watch.decline()
        for s in stride(from: 10.0, through: 120.0, by: 10.0) {
            _ = watchTick(&watch, now: t0.addingTimeInterval(s), url: "")
        }
        // Meet is back in front: declined holds for the rest of the call
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(130), url: Self.meetURL).action, .nothing)
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(140), url: Self.meetURL).action, .nothing)
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(150), url: Self.meetURL).action, .nothing)
        // it ends only when the browser lets the microphone go for good
        for s in stride(from: 160.0, through: 250.0, by: 10.0) {
            _ = watchTick(&watch, now: t0.addingTimeInterval(s), users: [], url: "")
        }
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(260), url: Self.meetURL).action, .nothing)
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(264), url: Self.meetURL).action,
                       .callStarted(source: "meet"), "a new call after a real hang-up is offered again")
    }

    /// Automation denied reads exactly like "no call" to the detector; the app must
    /// say so — once, not every poll (notice.meeting.browser_denied).
    /// Mutations: CallWatch.observe, replace `browserDenied: …` with `browserDenied: false` -> RED;
    /// or replace `!deniedReported` with `true` -> RED on the second assertion.
    func testADeniedBrowserSurfacesTheNoticeOnce() {
        var watch = CallWatch()
        var outcome = watch.observe(now: t0, users: chromeOnMic, tab: { _ in .denied },
                                    themActive: false, recording: nil)
        XCTAssertNil(outcome.call)
        XCTAssertEqual(outcome.action, .nothing)
        XCTAssertTrue(outcome.browserDenied, "a denied read is not 'no call' — surface the notice")
        outcome = watch.observe(now: t0.addingTimeInterval(2), users: chromeOnMic, tab: { _ in .denied },
                                themActive: false, recording: nil)
        XCTAssertFalse(outcome.browserDenied, "once per app run, not every poll")
    }

    /// The fallback keeps a call alive only while its app holds the microphone;
    /// a real hang-up (the mic released for good) still ends the episode.
    /// Mutation: CallWatch.observe, drop `CallDetector.holds(users, bundleID: last.bundleID)`
    /// from the fallback guard (feed lastCall unconditionally) -> RED.
    func testARealHangupStillEndsTheEpisode() {
        var watch = CallWatch()
        _ = watchTick(&watch, now: t0, url: Self.meetURL)
        for s in stride(from: 10.0, through: 100.0, by: 10.0) {
            _ = watchTick(&watch, now: t0.addingTimeInterval(s), users: [], url: "")
        }
        _ = watchTick(&watch, now: t0.addingTimeInterval(110), url: Self.meetURL)
        XCTAssertEqual(watchTick(&watch, now: t0.addingTimeInterval(114), url: Self.meetURL).action,
                       .callStarted(source: "meet"))
    }
}
