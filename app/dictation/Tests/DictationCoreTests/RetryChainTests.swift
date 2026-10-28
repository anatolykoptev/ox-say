import Foundation
import XCTest
@testable import DictationCore

/// A scheduler that holds the delayed work so a test runs it when it chooses, also after the chain moved on.
private final class FakeScheduler {
    var pending: [(delay: TimeInterval, work: () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { pending.append((delay, work)) }
    /// Runs and removes the oldest scheduled work.
    func runNext() { pending.removeFirst().work() }
}

/// #266: the microphone retry chain belongs to ONE recording. A chain left over from a recording that ended must not
/// act next to the new one.
final class RetryChainTests: XCTestCase {
    private struct Boom: Error {}

    private func chain(_ sched: FakeScheduler, attempt: @escaping () throws -> Void,
                       failed: @escaping (Error) -> Void = { _ in }, recovered: @escaping () -> Void = {}) -> RetryChain {
        RetryChain(attempt: attempt, schedule: { sched.schedule($0, $1) }, onFailed: failed, onRecovered: recovered)
    }

    /// Mutation: RetryChain.step, delete `guard generation == mine else { return }` in the scheduled closure -> RED
    /// (the stale chain from the first recording tries again, next to the second one).
    func testAStaleChainFromAnEarlierRecordingDoesNotAct() {
        let sched = FakeScheduler()
        var attempts = 0
        let c = chain(sched, attempt: { attempts += 1; throw Boom() })
        c.begin()
        c.run()                                  // recording 1: fails, a retry is scheduled
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sched.pending.count, 1)
        c.cancel()                               // recording 1 ends
        c.begin()                                // recording 2 begins
        sched.runNext()                          // the old timer fires
        XCTAssertEqual(attempts, 1, "the stale chain must not try again")
        XCTAssertTrue(sched.pending.isEmpty, "...nor schedule another step")
    }

    /// A route change during a pending retry starts a fresh chain; the pending one dies instead of running beside it.
    /// Mutation: RetryChain.run, delete `generation += 1` -> RED (two chains keep retrying).
    func testANewRunSupersedesAPendingRetry() {
        let sched = FakeScheduler()
        var attempts = 0
        let c = chain(sched, attempt: { attempts += 1; throw Boom() })
        c.begin()
        c.run()
        c.run()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sched.pending.count, 2)
        sched.runNext()                          // the first run's retry: superseded
        XCTAssertEqual(attempts, 2)
        sched.runNext()                          // the second run's retry: current
        XCTAssertEqual(attempts, 3)
    }

    /// The current chain still retries with the shared policy, tells the first failure of a streak and the recovery.
    func testTheCurrentChainRetriesToldOnceAndRecovers() {
        let sched = FakeScheduler()
        var attempts = 0
        var failures: [Error] = []
        var recovered = 0
        let c = chain(sched, attempt: { attempts += 1; if attempts < 3 { throw Boom() } },
                      failed: { failures.append($0) }, recovered: { recovered += 1 })
        c.begin()
        c.run()
        XCTAssertEqual(sched.pending.map(\.delay), [0.4])
        sched.runNext()
        XCTAssertEqual(sched.pending.map(\.delay), [1])
        sched.runNext()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(failures.count, 1, "only the first failure of a streak is told")
        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(sched.pending.isEmpty)
        // a later streak is told again
        let c2 = chain(sched, attempt: { throw Boom() }, failed: { failures.append($0) })
        c2.begin(); c2.run()
        XCTAssertEqual(failures.count, 2)
    }

    /// `begin` forgets the earlier recording's streak: its failures do not make the new first failure silent.
    /// Mutation: RetryChain.begin, delete `reacquire = Reacquire()` -> RED.
    func testBeginStartsAFreshStreak() {
        let sched = FakeScheduler()
        var failures = 0
        let c = chain(sched, attempt: { throw Boom() }, failed: { _ in failures += 1 })
        c.begin(); c.run()
        c.cancel()
        c.begin(); c.run()
        XCTAssertEqual(failures, 2)
    }

    /// Mutation: RetryChain.cancel, delete `generation += 1` -> RED (a cancelled chain still fires).
    func testACancelledChainStaysQuiet() {
        let sched = FakeScheduler()
        var attempts = 0
        let c = chain(sched, attempt: { attempts += 1; throw Boom() })
        c.begin(); c.run()
        c.cancel()
        sched.runNext()
        XCTAssertEqual(attempts, 1)
    }

    /// #337: the chain hands over the error itself, never a string of it: the app logs it and says its own sentence, so
    /// the framework's English cannot reach a Russian user through this callback.
    /// Mutation: RetryChain.step, `onFailed(error)` -> `onFailed(CancellationError())` -> RED.
    func testTheFirstFailureOfAStreakIsHandedOverAsTheErrorItself() {
        let sched = FakeScheduler()
        var heard: [Error] = []
        let c = chain(sched, attempt: { throw Boom() }, failed: { heard.append($0) })
        c.begin()
        c.run()
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(heard.first is Boom, "got \(String(describing: heard.first))")
    }
}
