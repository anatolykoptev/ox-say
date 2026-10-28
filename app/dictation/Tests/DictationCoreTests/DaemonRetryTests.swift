import XCTest
@testable import DictationCore

/// #211 — a dictation whose transcription fails while the daemon is down (an
/// install reloads its agent, a crash is relaunched) still has its whole
/// recording in hand: once the daemon answers /status again the held audio is
/// uploaded once more.
/// A clock the test owns: `sleep` moves it, and so can a probe that "takes" time.
final class FakeClock {
    var t: TimeInterval = 0
    func now() -> TimeInterval { t }
    func sleep(_ seconds: TimeInterval) async { t += seconds }
}

final class DaemonRetryTests: XCTestCase {
    @MainActor private func run(_ c: DictationController, until state: DictationState,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.state, state, "stuck: every later key press would be ignored", file: file, line: line)
    }

    // Journey: the daemon is dead when the recording finishes; it answers on
    // the third health probe and the held audio goes up once more — the text
    // is delivered and kept like any other dictation's.
    // Mutation: delete the `daemonRetry` block in DictationController.finish's
    // Task -> RED (the failure is reported at once, nothing is delivered).
    @MainActor
    func testAFailedTranscriptionIsRetriedOnceTheDaemonAnswers() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var attempts = 0
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in
            attempts += 1
            if attempts == 1 { throw TranscriptionError.daemonUnreachable("connection refused") }
            return "the held words"
        }
        var probes = 0
        c.daemonRetry = DaemonRetry(probe: { probes += 1; return probes >= 3 }, sleep: { _ in })
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(probes, 3, "the daemon is polled until it answers")
        XCTAssertEqual(attempts, 2, "the held recording is uploaded once more")
        XCTAssertEqual(out.delivered, ["the held words"])
        XCTAssertEqual(c.history.texts, ["the held words"], "the recovered text lands in Recent Dictations")
    }

    // The daemon never answers: the wait is bounded, the failure is reported
    // as before, and the held audio is not uploaded a second time.
    // Mutation: DaemonRetry.wait, drop `guard remaining > 0` -> the
    // controller never leaves .transcribing -> RED ("stuck").
    @MainActor
    func testADaemonThatNeverAnswersGivesUpInsideTheBudget() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var attempts = 0
        var errors: [String] = []
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in
            attempts += 1
            throw TranscriptionError.daemonUnreachable("connection refused")
        }
        c.onError = { errors.append($0) }
        var probes = 0
        var sleeps = 0
        let clock = FakeClock()
        c.daemonRetry = DaemonRetry(probe: { probes += 1; return false },
                                    budget: 3, interval: 1,
                                    sleep: { sleeps += 1; await clock.sleep($0) }, now: clock.now)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(attempts, 1, "the daemon never answered: no second upload")
        XCTAssertEqual(probes, 4, "a probe at once, then one after each of the budget's seconds")
        XCTAssertEqual(sleeps, 3, "a sleep between probes only")
        XCTAssertEqual(errors, ["The ox-say daemon is not reachable (connection refused). Is it running? Try `ox-say status`."],
                       "the failure is reported as before")
        XCTAssertEqual(out.delivered, [])
    }

    // Esc during the wait still wins: the dictation is dead, so nothing is
    // uploaded for it — the retry is for a restart, not a stay of execution.
    // Mutation: DictationController.finish, `retry.wait(live: { self.generation
    // == started })` -> `live: { true }` -> RED (probes keep growing past 2).
    @MainActor
    func testEscDuringTheWaitCancelsTheRetry() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var attempts = 0
        var errors = 0
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in
            attempts += 1
            throw TranscriptionError.daemonUnreachable("connection refused")
        }
        c.onError = { _ in errors += 1 }
        var events: [DaemonRetryEvent] = []
        c.onRetry = { events.append($0) }
        var probes = 0
        let clock = FakeClock()
        c.daemonRetry = DaemonRetry(probe: { [weak c] in
            probes += 1
            if probes == 2 { c?.cancel() } // Esc lands while the daemon is still down
            return false
        }, sleep: clock.sleep, now: clock.now)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        // The probe count stops growing at the Esc: without the `live:` gate the
        // wait would run on to the end of its budget (61 probes).
        XCTAssertEqual(probes, 2, "the wait polled the daemon on after the dictation was cancelled")
        XCTAssertEqual(attempts, 1, "a cancelled dictation is never re-uploaded")
        XCTAssertEqual(errors, 0, "Esc means silence, not an error notice")
        XCTAssertEqual(out.delivered, [])
        // #221.2: the wait that began also ends in the log.
        // Mutation: DictationController.finish, delete the `onRetry?(.cancelled(...))` call -> RED.
        XCTAssertEqual(events, [.started, .cancelled(waitedMs: 2000)])
        XCTAssertEqual(DaemonRetryEvent.cancelled(waitedMs: 1000).line, "daemon retry cancelled waited_ms=1000")
    }

    // The wait's own bounds, on the struct: it ends on the first answer,
    // spends at most budget/interval+1 probes, and a dead dictation spends none.
    func testTheWaitAnswersOnTheFirstLiveProbe() async {
        var probes = 0
        let retry = DaemonRetry(probe: { probes += 1; return true }, sleep: { _ in })
        let answered = await retry.wait(live: { true })
        XCTAssertTrue(answered)
        XCTAssertEqual(probes, 1, "the failure may already be over")
    }

    func testTheWaitIsBoundedByItsBudget() async {
        var probes = 0
        var sleeps = 0
        let clock = FakeClock()
        let retry = DaemonRetry(probe: { probes += 1; return false },
                                budget: 3, interval: 1,
                                sleep: { sleeps += 1; await clock.sleep($0) }, now: clock.now)
        let answered = await retry.wait(live: { true })
        XCTAssertFalse(answered)
        XCTAssertEqual(probes, 4)
        XCTAssertEqual(sleeps, 3)
    }

    // The cap is wall-clock, probes included: a daemon that accepts the
    // connection and hangs makes every probe take its full 3 s timeout. Counting
    // only the sleeps would allow 61 probes x 3 s = ~240 s.
    // Mutation: DaemonRetry.wait, measure `remaining` from the sleeps alone
    // (count `interval` per loop instead of `now() - start`) -> RED (61 probes,
    // ~240 fake seconds).
    func testTheCapIsWallClockTimeProbesIncluded() async {
        var probes = 0
        let clock = FakeClock()
        let retry = DaemonRetry(probe: { probes += 1; clock.t += 3; return false },
                                budget: 60, interval: 1, sleep: clock.sleep, now: clock.now)
        let answered = await retry.wait(live: { true })
        XCTAssertFalse(answered)
        XCTAssertLessThanOrEqual(clock.t, 60 + 3, "over the budget by more than the one probe that was in flight")
        XCTAssertEqual(probes, 16, "each round costs a 3 s probe and a 1 s sleep")
    }

    // The last sleep is cut to what is left of the budget.
    func testTheLastSleepDoesNotOvershootTheBudget() async {
        let clock = FakeClock()
        let retry = DaemonRetry(probe: { false }, budget: 2.5, interval: 1, sleep: clock.sleep, now: clock.now)
        _ = await retry.wait(live: { true })
        XCTAssertEqual(clock.t, 2.5, accuracy: 0.0001)
    }

    func testADeadDictationEndsTheWaitWithoutAProbe() async {
        var probes = 0
        let retry = DaemonRetry(probe: { probes += 1; return true }, sleep: { _ in })
        let answered = await retry.wait(live: { false })
        XCTAssertFalse(answered)
        XCTAssertEqual(probes, 0)
    }

    // Which failures get the wait: only a daemon that did not answer. A timeout
    // means the daemon is alive and busy (a retry would sit in .transcribing for
    // ~22 more minutes); an HTTP error or a response without text fails the same
    // way again.
    // Mutation: DaemonRetry.worthWaiting, return true (drop the class check) ->
    // RED on the three not-retried tests below.
    @MainActor
    private func failOnce(_ error: TranscriptionError) async -> (attempts: Int, probes: Int, errors: [String],
                                                                 events: [DaemonRetryEvent], timing: DictationTiming?) {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var attempts = 0
        var errors: [String] = []
        var events: [DaemonRetryEvent] = []
        var timing: DictationTiming?
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in
            attempts += 1
            throw error
        }
        c.onError = { errors.append($0) }
        c.onRetry = { events.append($0) }
        c.onTiming = { timing = $0 }
        var probes = 0
        let clock = FakeClock()
        c.daemonRetry = DaemonRetry(probe: { probes += 1; return true }, sleep: clock.sleep, now: clock.now)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        return (attempts, probes, errors, events, timing)
    }

    @MainActor
    func testATimeoutIsNotRetried() async {
        let r = await failOnce(.timedOut)
        XCTAssertEqual(r.attempts, 1, "a timed-out upload is not sent again: the daemon is busy, not dead")
        XCTAssertEqual(r.probes, 0, "no wait for a daemon that answered")
        XCTAssertEqual(r.errors, [TranscriptionError.timedOut.description])
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(r.timing?.retried, false)
    }

    @MainActor
    func testAnHTTPErrorIsNotRetried() async {
        let r = await failOnce(.http(400, "invalid multipart body"))
        XCTAssertEqual(r.attempts, 1, "a 4xx fails the same way again")
        XCTAssertEqual(r.probes, 0)
        XCTAssertEqual(r.errors, [TranscriptionError.http(400, "invalid multipart body").description])
        XCTAssertEqual(r.events, [])
    }

    @MainActor
    func testAResponseWithoutTextIsNotRetried() async {
        let r = await failOnce(.badResponse)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(r.probes, 0)
        XCTAssertEqual(r.errors, [TranscriptionError.badResponse.description])
        XCTAssertEqual(r.events, [])
    }

    // 503 is the daemon's full queue (stt.ErrBusy) or a missing model — it is up
    // and answering, so it is not a restart signature either.
    @MainActor
    func testA503IsNotRetried() async {
        let r = await failOnce(.http(503, "stt: queue full"))
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(r.probes, 0)
    }

    @MainActor
    func testAnUnreachableDaemonIsRetried() async {
        let r = await failOnce(.daemonUnreachable("connection refused"))
        XCTAssertEqual(r.probes, 1, "the daemon is polled")
        XCTAssertEqual(r.attempts, 2, "the held audio goes up once more")
    }

    // Observability: one event when the wait starts, one when it ends, and the
    // timing line says the dictation was retried and for how long.
    // Mutation: DictationController.finish, drop `retried = true` or the
    // `onRetry?(...)` calls -> RED.
    @MainActor
    func testARecoveredRetryIsLoggedAndMarkedOnTheTimingLine() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        var attempts = 0
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold) { _ in
            attempts += 1
            if attempts == 1 { throw TranscriptionError.daemonUnreachable("connection refused") }
            return "the held words"
        }
        var events: [DaemonRetryEvent] = []
        var timing: DictationTiming?
        c.onRetry = { events.append($0) }
        c.onTiming = { timing = $0 }
        var probes = 0
        let clock = FakeClock()
        c.daemonRetry = DaemonRetry(probe: { probes += 1; return probes >= 3 },
                                    interval: 2, sleep: clock.sleep, now: clock.now)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(events, [.started, .recovered(waitedMs: 4000)])
        XCTAssertEqual(timing?.retried, true)
        XCTAssertEqual(timing?.waitedMs, 4000)
        XCTAssertTrue(timing?.line.hasSuffix("delivery=paste retried=1 waited_ms=4000") ?? false, timing?.line ?? "no timing")
    }

    @MainActor
    func testAGivenUpRetryIsLoggedAndMarkedOnTheTimingLine() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold) { _ in
            throw TranscriptionError.daemonUnreachable("connection refused")
        }
        var events: [DaemonRetryEvent] = []
        var timing: DictationTiming?
        c.onRetry = { events.append($0) }
        c.onTiming = { timing = $0 }
        let clock = FakeClock()
        c.daemonRetry = DaemonRetry(probe: { false }, budget: 3, interval: 1, sleep: clock.sleep, now: clock.now)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(events, [.started, .gaveUp(waitedMs: 3000)])
        XCTAssertEqual(timing?.outcome, .failed)
        XCTAssertTrue(timing?.line.hasSuffix("delivery=none retried=1 waited_ms=3000") ?? false, timing?.line ?? "no timing")
    }

    // A dictation that was never retried keeps its line byte-identical.
    // Mutation: DictationTiming.line, append the retry fields unconditionally
    // -> RED (every ordinary line grows).
    func testAnOrdinaryTimingLineCarriesNoRetryFields() {
        let timing = DictationTiming(recordedSeconds: 1, releaseToTextMs: 900,
                                     stats: TranscriberStats(path: .oneShot), outcome: .delivered, delivery: .paste)
        XCTAssertFalse(timing.line.contains("retried"))
        XCTAssertFalse(timing.line.contains("waited_ms"))
        let retried = DictationTiming(recordedSeconds: 1, releaseToTextMs: 900,
                                      stats: TranscriberStats(path: .oneShot), outcome: .delivered, delivery: .paste,
                                      retried: true, waitedMs: 1500)
        XCTAssertEqual(retried.line, timing.line + " retried=1 waited_ms=1500")
    }

    func testRetryEventLinesCarryNoText() {
        XCTAssertEqual(DaemonRetryEvent.started.line, "daemon retry started")
        XCTAssertEqual(DaemonRetryEvent.recovered(waitedMs: 1200).line, "daemon retry recovered waited_ms=1200")
        XCTAssertEqual(DaemonRetryEvent.gaveUp(waitedMs: 60000).line, "daemon retry gave_up waited_ms=60000")
    }

    // The probe is "the daemon answered /status": a transport error is down, an
    // HTTP error is down — but a 200 with no stt_server (an older daemon) is
    // up, where sttServerState() reads nil.
    // Mutation: reachable() drops the 200 check -> RED (a 500 counts as up).
    func testReachableFollowsTheStatusAnswer() async {
        let up = TranscriptionClient { req in
            XCTAssertEqual(req.url!.path, "/status")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"engine":{"state":"ready"}}"#.utf8), resp)
        }
        let upAnswered = await up.reachable()
        XCTAssertTrue(upAnswered, "a 200 with no stt_server still means the daemon answered")

        let down = TranscriptionClient { _ in throw URLError(.cannotConnectToHost) }
        let downAnswered = await down.reachable()
        XCTAssertFalse(downAnswered)

        let broken = TranscriptionClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let brokenAnswered = await broken.reachable()
        XCTAssertFalse(brokenAnswered, "a 500 is not an answer the retry should ride on")
    }
}

/// The AppDelegate wiring the unit tests cannot reach, gated by reading the
/// source — the style of `NeverLoseWiringTests`.
final class DaemonRetryWiringTests: XCTestCase {
    private static var appDelegateSource: String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    // F1 (call site) — the retry exists but is inert unless the app arms it on
    // the transcription client. Mutation: delete the `controller.daemonRetry =`
    // line in applicationDidFinishLaunching -> RED; point the probe somewhere
    // else -> RED.
    func testTheControllerIsArmedWithTheDaemonHealthProbe() {
        let source = Self.appDelegateSource
        XCTAssertFalse(source.isEmpty, "AppDelegate.swift unreadable — the wiring guard has nothing to check")
        XCTAssertTrue(source.contains("controller.daemonRetry = DaemonRetry("),
                      "no daemon-restart retry: a dictation that dies with the daemon is still lost")
        XCTAssertTrue(source.contains("client.reachable()"),
                      "the retry must poll the daemon's health on the existing transcription client")
    }

    // The retry's start and end reach the unified log. Mutation: delete the
    // `controller.onRetry =` line in applicationDidFinishLaunching -> RED.
    func testTheRetryIsLogged() {
        let source = Self.appDelegateSource
        XCTAssertTrue(source.contains(#"controller.onRetry = { event in timingLog.notice("\(event.line, privacy: .public)") }"#),
                      "the retry leaves no trace in the log")
    }
}
