import XCTest
@testable import DictationCore

@MainActor
final class CleanSessionTests: XCTestCase {
    private let input = URL(fileURLWithPath: "/x/in.mov")
    private let output = URL(fileURLWithPath: "/x/in-clean.mov")
    private let result = CleanResult(outPath: "/x/in-clean.mov", video: true, inputSeconds: 60, elapsedSeconds: 3)
    private var available: DaemonStatus { DaemonStatus(version: "v", studioAvailable: false, voiceClean: CleanStatus(available: true)) }

    /// A clean that waits until it is cancelled, as the real request does (URLSession throws when the task is cancelled).
    private func hanging() -> CleanOps {
        CleanOps(clean: { _, _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CleanError(.failed)
        })
    }

    private func session(_ ops: CleanOps) -> CleanSession {
        let s = CleanSession(ops: ops)
        s.statusRead(available)
        return s
    }

    private func until(_ s: CleanSession, _ done: @escaping (CleanActionState) -> Bool) async {
        for _ in 0..<400 where !done(s.state) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testASuccessfulJobEndsDoneWithBothFiles() async {
        let r = result
        let s = session(CleanOps(clean: { _, _, _, _ in r }))
        XCTAssertNil(s.start(input: input, output: output, overwrite: false))
        XCTAssertEqual(s.state, .working(name: "in-clean.mov", cancelling: false))
        await until(s) { if case .done = $0 { return true } else { return false } }
        XCTAssertEqual(s.state, .done(CleanDone(inputPath: "/x/in.mov", outputPath: "/x/in-clean.mov", video: true, seconds: 60)))
    }

    /// The call gets the picked file, the chosen output, the overwrite flag and the measured length.
    func testTheCallReceivesWhatWasChosen() async {
        var seen: (URL, URL, Bool, Double?)?
        let r = result
        let s = session(CleanOps(clean: { i, o, w, d in seen = (i, o, w, d); return r }, duration: { _ in 61.5 }))
        s.start(input: input, output: output, overwrite: true)
        await until(s) { if case .done = $0 { return true } else { return false } }
        XCTAssertEqual(seen?.0, input); XCTAssertEqual(seen?.1, output); XCTAssertEqual(seen?.2, true); XCTAssertEqual(seen?.3, 61.5)
    }

    /// Cancel is not a failure: the bar returns to the start, with no sentence, once the request has ended.
    /// Mutation: CleanSession.run, drop `error is CancellationError` and `Task.isCancelled` from the guard -> RED.
    func testCancelEndsTheJobWithoutAFailure() async {
        let s = session(hanging())
        s.start(input: input, output: output, overwrite: false)
        s.cancel()
        XCTAssertEqual(s.state, .working(name: "in-clean.mov", cancelling: true), "says so until the request has ended")
        await until(s) { if case .working = $0 { return false } else { return true } }
        XCTAssertEqual(s.state, .idle(firstUse: false))
        XCTAssertNil(s.failure)
    }

    /// Mutation: CleanSession.cancel, remove `job?.cancel()` -> RED (the job never ends).
    func testCancelReallyStopsTheRequest() async {
        var cancelled = false
        let s = session(CleanOps(clean: { _, _, _, _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled = true; throw error }
            throw CleanError(.failed)
        }))
        s.start(input: input, output: output, overwrite: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        s.cancel()
        await until(s) { if case .working = $0 { return false } else { return true } }
        XCTAssertTrue(cancelled)
    }

    /// A transport that wraps the cancel in another error is still no failure.
    func testACancelReportedAsAnotherErrorIsStillNoFailure() async {
        let s = session(CleanOps(clean: { _, _, _, _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { throw StudioError.daemonUnreachable }
            throw CleanError(.failed)
        }))
        s.start(input: input, output: output, overwrite: false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        s.cancel()
        await until(s) { if case .working = $0 { return false } else { return true } }
        XCTAssertNil(s.failure)
    }

    /// Mutation: CleanSession.sentence, return the plain fallback for a CleanError -> RED.
    func testAFailureIsTheProblemsOwnSentenceAndTheNextJobIsFree() async {
        let s = session(CleanOps(clean: { _, _, _, _ in throw CleanError(.diskFull) }))
        s.start(input: input, output: output, overwrite: false)
        await until(s) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(s.state, .failed(CleanProblem.diskFull.sentence()))
        XCTAssertNil(s.start(input: input, output: output, overwrite: false), "a failed job leaves the next one free")
        s.cancel()
    }

    func testTransportErrorsAreStudioSentences() async {
        let s = session(CleanOps(clean: { _, _, _, _ in throw StudioError.daemonUnreachable }))
        s.start(input: input, output: output, overwrite: false)
        await until(s) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(s.state, .failed(StudioError.daemonUnreachable.message()))
    }

    /// One file at a time.
    /// Mutation: CleanSession.start, remove the `working != nil` guard -> RED.
    func testASecondFileWhileOneRunsIsRefusedWithASentence() {
        let s = session(hanging())
        XCTAssertNil(s.start(input: input, output: output, overwrite: false))
        XCTAssertEqual(s.start(input: input, output: URL(fileURLWithPath: "/x/other.mov"), overwrite: false), CleanProblem.busy.sentence())
        XCTAssertEqual(s.working?.name, "in-clean.mov")
        s.cancel()
    }

    /// An unavailable cleaner never starts, whatever the caller does.
    /// Mutation: CleanSession.start, remove the `.unavailable` guard -> RED.
    func testNothingStartsWhileTheCleanerIsUnavailable() {
        let s = CleanSession(ops: hanging())
        s.statusRead(DaemonStatus(version: "v", studioAvailable: false, voiceClean: CleanStatus(available: false, reasonCode: "os_too_old")))
        XCTAssertEqual(s.start(input: input, output: output, overwrite: false), L10nKey.cleanReasonOSTooOld.text)
        XCTAssertNil(s.working)
    }

    func testDismissClosesADoneJobButNeverARunningOne() async {
        let r = result
        let s = session(CleanOps(clean: { _, _, _, _ in r }))
        s.start(input: input, output: output, overwrite: false)
        s.dismiss()
        XCTAssertNotNil(s.working, "a running job cannot be dismissed")
        await until(s) { if case .done = $0 { return true } else { return false } }
        s.dismiss()
        XCTAssertEqual(s.state, .idle(firstUse: false))
    }

    func testStartingAgainReplacesTheOldResult() async {
        let r = result
        let s = session(CleanOps(clean: { _, _, _, _ in r }))
        s.start(input: input, output: output, overwrite: false)
        await until(s) { if case .done = $0 { return true } else { return false } }
        s.start(input: input, output: output, overwrite: true)
        XCTAssertEqual(s.state, .working(name: "in-clean.mov", cancelling: false))
        XCTAssertNil(s.done)
    }
}
