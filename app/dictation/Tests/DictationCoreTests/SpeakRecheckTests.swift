import XCTest
@testable import DictationCore

/// #490: nothing polls for the Озвучка page, so a daemon that was not up at first launch left "unavailable" on screen
/// until «Повторить». While the page is visible and offline it asks again by itself, gently and backing off.
final class SpeakRecheckTests: XCTestCase {
    private let down = DaemonReach.unreachable("down")

    func testAVisibleOfflineOzvuchkaAsksAgainAndBacksOff() throws {
        var previous: TimeInterval = 0
        for misses in 1...12 {
            let delay = SpeakRecheck.delay(visible: true, section: .speak, reach: down, misses: misses)
            let seconds = try XCTUnwrap(delay)
            XCTAssertGreaterThanOrEqual(seconds, max(previous, ProduceText.pollInterval), "backing off never speeds the asking up")
            XCTAssertLessThanOrEqual(seconds, VoiceoverFollower.maxBackoff)
            previous = seconds
        }
        XCTAssertEqual(SpeakRecheck.delay(visible: true, section: .speak, reach: down, misses: 1), ProduceText.pollInterval)
        XCTAssertEqual(SpeakRecheck.delay(visible: true, section: .speak, reach: down, misses: 50), VoiceoverFollower.maxBackoff)
    }

    func testNothingIsAskedWhenTheDaemonAnswersOrThePageIsNotInView() {
        XCTAssertNil(SpeakRecheck.delay(visible: true, section: .speak, reach: .reachable, misses: 0))
        XCTAssertNil(SpeakRecheck.delay(visible: true, section: .speak, reach: .unknown, misses: 0))
        XCTAssertNil(SpeakRecheck.delay(visible: false, section: .speak, reach: down, misses: 3), "a hidden window polls nothing")
        XCTAssertNil(SpeakRecheck.delay(visible: true, section: .meetings, reach: down, misses: 3), "another section is not this page's to poll")
    }

    func testTheTrackerCountsConsecutiveMissesForTheBackoff() {
        var tracker = ReachTracker()
        XCTAssertEqual(tracker.misses, 0)
        tracker.record(answered: false, sentence: "x")
        tracker.record(answered: false, sentence: "x")
        XCTAssertEqual(tracker.misses, 2)
        tracker.record(answered: true, sentence: "x")
        XCTAssertEqual(tracker.misses, 0)
    }
}
