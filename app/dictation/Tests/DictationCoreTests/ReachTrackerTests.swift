import XCTest
@testable import DictationCore

final class ReachTrackerTests: XCTestCase {
    func testTheFirstMissWithNothingYetKnownIsOffline() {
        var t = ReachTracker()
        t.record(answered: false, sentence: "down")
        XCTAssertEqual(t.reach, .unreachable("down"))
    }

    /// One missed poll must not replace a running job's progress or a finished result.
    func testOneMissedPollAfterAnAnswerDoesNotGoOffline() {
        var t = ReachTracker()
        t.record(answered: true, sentence: "down")
        t.record(answered: false, sentence: "down")
        XCTAssertEqual(t.reach, .reachable)
        XCTAssertTrue(t.waiting, "the numbers may be old: ProduceText.progressRow(serviceWaiting:) says so")
        t.record(answered: false, sentence: "down")
        XCTAssertEqual(t.reach, .unreachable("down"), "the second miss in a row is offline")
        XCTAssertEqual(ReachTracker.missedPollsBeforeOffline, 2)
    }

    func testAnAnswerClearsTheMisses() {
        var t = ReachTracker()
        t.record(answered: true, sentence: "x")
        t.record(answered: false, sentence: "x")
        t.record(answered: true, sentence: "x")
        t.record(answered: false, sentence: "x")
        XCTAssertEqual(t.reach, .reachable, "the misses were not consecutive")
        XCTAssertFalse(ReachTracker().waiting)
        t.record(answered: true, sentence: "x")
        XCTAssertFalse(t.waiting)
    }

    func testAnOfflinePageRecoversOnTheFirstAnswer() {
        var t = ReachTracker()
        t.record(answered: false, sentence: "x")
        t.record(answered: true, sentence: "x")
        XCTAssertEqual(t.reach, .reachable)
    }
}
