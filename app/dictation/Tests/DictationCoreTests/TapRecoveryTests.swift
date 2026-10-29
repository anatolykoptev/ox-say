import XCTest
@testable import DictationCore

/// #302: the recorder's answer handling for a tap start or rebuild, driven without CoreAudio. The recorder hands
/// `TapRecovery.answer` the tap's state and carries the action out (MeetingWiringTests pins that call site).
final class TapRecoveryTests: XCTestCase {
    private func failing(_ r: inout TapRecovery, token: Int, hasTap: Bool = true, silence: TimeInterval? = 0.01,
                         recording: Bool = true) -> TapRecovery.Action {
        r.answer(.failed, token: token, recording: recording, hasTap: hasTap, sinceLastBuffer: silence)
    }

    /// A rebuild that failed while the old tap delivers is retried and not told; a silent old tap is told once, and the
    /// recovery after it is told once.
    /// Mutation: TapRecovery.answer, `sourceLost: lost` -> `sourceLost: true` -> RED (the live-tap row is told).
    func testALiveOldTapIsNotToldAndASilentOneIsToldOnce() {
        var r = TapRecovery(); r.begin()
        let t = r.token
        XCTAssertEqual(failing(&r, token: t), .rebuild(after: 0.4, tellLoss: false, previousKeepsDelivering: true))
        XCTAssertEqual(failing(&r, token: t, silence: 5), .rebuild(after: 1, tellLoss: true, previousKeepsDelivering: false))
        XCTAssertEqual(failing(&r, token: t, silence: 6), .rebuild(after: 2, tellLoss: false, previousKeepsDelivering: false), "told once per streak")
        XCTAssertEqual(r.answer(.started, token: t, recording: true, hasTap: true, sinceLastBuffer: 0), .recovered)
        XCTAssertEqual(r.answer(.started, token: t, recording: true, hasTap: true, sinceLastBuffer: 0), .nothing, "a second start has no streak")
    }

    /// A streak that was never told has no recovery to tell.
    func testAQuietStreakHasNoRecovery() {
        var r = TapRecovery(); r.begin()
        _ = failing(&r, token: r.token)
        XCTAssertEqual(r.answer(.started, token: r.token, recording: true, hasTap: true, sinceLastBuffer: 0), .nothing)
    }

    /// An answer for a recording that is over, or for an earlier one, is dropped without touching the streak.
    /// Mutation: TapRecovery.answer, delete `generation.isCurrent(token)` from the guard -> RED (the stale failure is told).
    func testAStaleAnswerIsIgnoredAndLeavesTheStreakAlone() {
        var r = TapRecovery(); r.begin()
        let first = r.token
        r.end()
        r.begin()
        XCTAssertEqual(failing(&r, token: first, hasTap: false, silence: nil), .ignore, "an earlier recording's answer")
        XCTAssertEqual(failing(&r, token: r.token, hasTap: true, silence: 0.01), .rebuild(after: 0.4, tellLoss: false, previousKeepsDelivering: true),
                       "the stale answer did not burn the new streak")
        XCTAssertEqual(r.answer(.started, token: first, recording: true, hasTap: true, sinceLastBuffer: 0), .ignore)
    }

    /// Mutation: TapRecovery.answer, delete `recording` from the guard -> RED.
    func testNothingHappensWhenNoRecordingRuns() {
        var r = TapRecovery(); r.begin()
        XCTAssertEqual(failing(&r, token: r.token, recording: false), .ignore)
        XCTAssertEqual(r.answer(.started, token: r.token, recording: false, hasTap: true, sinceLastBuffer: 0), .ignore)
    }

    /// `end` makes in-flight answers stale; `begin` starts a fresh streak (the retry delay starts over).
    /// Mutation: TapRecovery.begin, delete `retry = Reacquire()` -> RED (the delay carries over).
    func testABeginStartsAFreshStreak() {
        var r = TapRecovery(); r.begin()
        _ = failing(&r, token: r.token, silence: 5)
        let old = r.token
        r.end()
        XCTAssertEqual(failing(&r, token: old), .ignore, "answered after stop")
        r.begin()
        XCTAssertEqual(failing(&r, token: r.token, silence: 5), .rebuild(after: 0.4, tellLoss: true, previousKeepsDelivering: false))
    }

    /// A stop answer ends nothing and tells nothing.
    func testAStopAnswerDoesNothing() {
        var r = TapRecovery(); r.begin()
        XCTAssertEqual(r.answer(.stopped, token: r.token, recording: true, hasTap: false, sinceLastBuffer: nil), .nothing)
    }

    /// The backstop: five failures in a row are told even if the old tap keeps delivering.
    func testTheFifthFailureIsToldWhateverTheOldTapDoes() {
        var r = TapRecovery(); r.begin()
        var told = [Bool]()
        for _ in 0..<5 {
            if case .rebuild(_, let tell, _) = failing(&r, token: r.token) { told.append(tell) }
        }
        XCTAssertEqual(told, [false, false, false, false, true])
    }
}
