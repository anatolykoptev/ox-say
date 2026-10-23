import XCTest
@testable import DictationCore

/// #211 — a dictation whose transcription fails while the daemon is down (an
/// install reloads its agent, a crash is relaunched) still has its whole
/// recording in hand: once the daemon answers /status again the held audio is
/// uploaded once more.
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
    // Mutation: DaemonRetry.wait, drop `guard waited < budget` -> the
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
        c.daemonRetry = DaemonRetry(probe: { probes += 1; return false },
                                    budget: 3, interval: 1, sleep: { _ in sleeps += 1 })
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
        var probes = 0
        c.daemonRetry = DaemonRetry(probe: { [weak c] in
            probes += 1
            if probes == 2 { c?.cancel() } // Esc lands while the daemon is still down
            return false
        }, sleep: { _ in })
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(attempts, 1, "a cancelled dictation is never re-uploaded")
        XCTAssertEqual(errors, 0, "Esc means silence, not an error notice")
        XCTAssertEqual(out.delivered, [])
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
        let retry = DaemonRetry(probe: { probes += 1; return false },
                                budget: 3, interval: 1, sleep: { _ in sleeps += 1 })
        let answered = await retry.wait(live: { true })
        XCTAssertFalse(answered)
        XCTAssertEqual(probes, 4)
        XCTAssertEqual(sleeps, 3)
    }

    func testADeadDictationEndsTheWaitWithoutAProbe() async {
        var probes = 0
        let retry = DaemonRetry(probe: { probes += 1; return true }, sleep: { _ in })
        let answered = await retry.wait(live: { false })
        XCTAssertFalse(answered)
        XCTAssertEqual(probes, 0)
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
}
