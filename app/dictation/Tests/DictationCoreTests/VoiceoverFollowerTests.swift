import XCTest
@testable import DictationCore

/// A daemon whose every answer the test gives by hand: a call waits until the
/// test resumes it, so the order of events is the test's.
private final class FakeDaemon {
    var polls: [CheckedContinuation<ProduceJob, Error>] = []
    var lists: [CheckedContinuation<[ProduceJob], Error>] = []
    var delays: [TimeInterval] = []

    func source() -> VoiceoverFollower.Source {
        VoiceoverFollower.Source(
            voiceover: { _ in try await withCheckedThrowingContinuation { self.polls.append($0) } },
            voiceovers: { try await withCheckedThrowingContinuation { self.lists.append($0) } },
            sleep: { seconds in
                self.delays.append(seconds)
                await Task.yield()
            })
    }
}

private func job(_ status: ProduceStatus, id: String = "j") -> ProduceJob {
    ProduceJob(id: id, title: "Ch 1", status: status, partsTotal: 5, partsDone: 2)
}

/// Lets the follower's tasks run until `condition` holds.
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { await Task.yield() }
}

final class VoiceoverFollowerTests: XCTestCase {
    private struct Down: Error {}

    private func makeFollower(_ daemon: FakeDaemon, changes: @escaping () -> Void = {},
                              finished: @escaping (ProduceJob) -> Void = { _ in }) -> VoiceoverFollower {
        VoiceoverFollower(source: daemon.source(), onChange: changes, onFinish: finished)
    }

    func testTheWaitBetweenPollsNeverShrinksBelowTheNormalIntervalAndIsCapped() {
        XCTAssertEqual(VoiceoverFollower.delay(afterFailures: 0), ProduceText.pollInterval)
        var previous = ProduceText.pollInterval
        for failures in 1...20 {
            let delay = VoiceoverFollower.delay(afterFailures: failures)
            XCTAssertGreaterThanOrEqual(delay, previous, "backing off never speeds polling up")
            XCTAssertLessThanOrEqual(delay, VoiceoverFollower.maxBackoff)
            previous = delay
        }
        XCTAssertEqual(VoiceoverFollower.delay(afterFailures: 20), VoiceoverFollower.maxBackoff)
    }

    /// Mutation: VoiceoverFollower.swift follow, the `catch {` branch ends with
    /// `return` (stop on the first failure) -> RED.
    func testAnOutageOfTheServiceDoesNotDropTheJob() async {
        let daemon = FakeDaemon()
        var changes = 0
        var finished: [ProduceJob] = []
        let follower = makeFollower(daemon, changes: { changes += 1 }, finished: { finished.append($0) })
        follower.follow(job(.running))

        for round in 1...20 {
            await settle { daemon.polls.count == round }
            guard daemon.polls.count == round else { return XCTFail("poll \(round) was never made: the follower gave up") }
            daemon.polls[round - 1].resume(throwing: StudioError.daemonUnreachable)
            await settle { follower.serviceWaiting && daemon.polls.count == round + 1 || round == 20 }
            XCTAssertNotNil(follower.job, "still following after \(round) failed polls")
            XCTAssertTrue(follower.serviceWaiting)
        }
        XCTAssertTrue(finished.isEmpty)

        // The service is back and the job moved on.
        await settle { daemon.polls.count == 21 }
        guard daemon.polls.count == 21 else { return XCTFail("the follower never polled again") }
        daemon.polls[20].resume(returning: job(.running))
        await settle { !follower.serviceWaiting }
        XCTAssertFalse(follower.serviceWaiting)
        XCTAssertGreaterThan(changes, 0)
        follower.stop()
    }

    func testBackingOffNeverPollsMoreOftenThanTheNormalInterval() async {
        let daemon = FakeDaemon()
        let follower = makeFollower(daemon)
        follower.follow(job(.running))
        for round in 1...8 {
            await settle { daemon.polls.count == round }
            guard daemon.polls.count == round else { return XCTFail("poll \(round) was never made") }
            daemon.polls[round - 1].resume(throwing: Down())
        }
        await settle { daemon.delays.count >= 9 }
        XCTAssertTrue(daemon.delays.allSatisfy { $0 >= ProduceText.pollInterval }, "delays: \(daemon.delays)")
        XCTAssertGreaterThan(daemon.delays.last ?? 0, daemon.delays.first ?? 0)
        follower.stop()
    }

    /// Mutation: VoiceoverFollower.swift follow, the 404 `catch` branch deleted
    /// (a 404 then counts as an outage and the job is followed forever) -> RED.
    func testOnlyATerminalStateOrA404StopsFollowing() async {
        let daemon = FakeDaemon()
        var finished: [ProduceJob] = []
        let follower = makeFollower(daemon, finished: { finished.append($0) })

        follower.follow(job(.running))
        await settle { daemon.polls.count == 1 }
        guard daemon.polls.count == 1 else { return XCTFail("no poll") }
        daemon.polls[0].resume(throwing: StudioError.refused(status: 404, message: "gone"))
        await settle { follower.job == nil }
        XCTAssertNil(follower.job, "a 404: the daemon does not know the job")
        XCTAssertTrue(finished.isEmpty)

        let daemon2 = FakeDaemon()
        var finished2: [ProduceJob] = []
        let second = makeFollower(daemon2, finished: { finished2.append($0) })
        second.follow(job(.running))
        await settle { daemon2.polls.count == 1 }
        guard daemon2.polls.count == 1 else { return XCTFail("no poll") }
        daemon2.polls[0].resume(returning: job(.done))
        await settle { !finished2.isEmpty }
        XCTAssertEqual(finished2.map(\.status), [.done])
        await settle { false } // time for a stray extra poll
        XCTAssertEqual(daemon2.polls.count, 1, "no poll after the terminal state")
    }

    /// Mutation: VoiceoverFollower.swift follow, delete the `guard !Task.isCancelled`
    /// line after `try await source.voiceover(id)` -> the cancelled follower
    /// presents the finish too -> RED.
    func testACancelledFollowerNeverPresentsTheFinish() async {
        let daemon = FakeDaemon()
        var finished: [ProduceJob] = []
        let follower = makeFollower(daemon, finished: { finished.append($0) })

        follower.follow(job(.running))
        await settle { daemon.polls.count == 1 }
        follower.follow(job(.running)) // the same job again: the first follower is cancelled mid-poll
        await settle { daemon.polls.count == 2 }
        guard daemon.polls.count == 2 else { return XCTFail("the second follower never polled") }

        daemon.polls[0].resume(returning: job(.done)) // the cancelled one answers
        await settle { !finished.isEmpty }
        XCTAssertTrue(finished.isEmpty, "a cancelled follower presented the finish")

        daemon.polls[1].resume(returning: job(.done))
        await settle { !finished.isEmpty }
        XCTAssertEqual(finished.count, 1, "the finish is presented exactly once")
    }

    // MARK: picking up a voiceover that is already running

    func testNoPickUpAttemptWithoutAnAnsweredStatus() async {
        let daemon = FakeDaemon()
        let follower = makeFollower(daemon)
        await settle { false }
        XCTAssertTrue(daemon.lists.isEmpty)
        XCTAssertNil(follower.job)
    }

    /// Mutation: VoiceoverFollower.swift serviceAnswered, set `self.pickedUp = true`
    /// before `guard let jobs` (a failed read counts as done) -> RED.
    func testAFailedPickUpIsRetriedOnTheNextAnsweredStatusUntilItSucceedsOnce() async {
        let daemon = FakeDaemon()
        let follower = makeFollower(daemon)

        follower.serviceAnswered()
        await settle { daemon.lists.count == 1 }
        follower.serviceAnswered()
        await settle { false }
        XCTAssertEqual(daemon.lists.count, 1, "one attempt at a time")
        guard daemon.lists.count == 1 else { return XCTFail("no pick-up attempt") }
        daemon.lists[0].resume(throwing: StudioError.daemonUnreachable)
        await settle { false }
        XCTAssertNil(follower.job)

        follower.serviceAnswered() // the next successful /status
        await settle { daemon.lists.count == 2 }
        guard daemon.lists.count == 2 else { return XCTFail("not retried after the failure") }
        daemon.lists[1].resume(returning: [job(.done, id: "old"), job(.running, id: "live")])
        await settle { follower.job != nil }
        XCTAssertEqual(follower.job?.id, "live", "the running voiceover is picked up")

        follower.serviceAnswered()
        await settle { false }
        XCTAssertEqual(daemon.lists.count, 2, "after one success the list is not read again")
        follower.stop()
    }

    func testPickUpDoesNotTakeOverAVoiceoverTheAppIsAlreadyFollowing() async {
        let daemon = FakeDaemon()
        let follower = makeFollower(daemon)
        follower.serviceAnswered()
        await settle { daemon.lists.count == 1 }
        guard daemon.lists.count == 1 else { return XCTFail("no pick-up attempt") }
        follower.follow(job(.running, id: "mine"))
        daemon.lists[0].resume(returning: [job(.running, id: "other")])
        await settle { false }
        XCTAssertEqual(follower.job?.id, "mine")
        follower.stop()
    }
}
