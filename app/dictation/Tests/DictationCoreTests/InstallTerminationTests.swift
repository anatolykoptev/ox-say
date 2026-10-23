import XCTest
@testable import DictationCore

/// #198: an update install never ends the app while a dictation records or
/// transcribes. The wait and the SIGTERM rule are pure; the AppDelegate call
/// sites are gated by reading the sources.
final class InstallTerminationTests: XCTestCase {
    /// A state that turns idle after `sleeps` waits; counts every wait.
    private final class Dictation {
        var state: DictationState
        var slept = 0
        private let idleAfter: Int?
        init(_ state: DictationState, idleAfter: Int?) { self.state = state; self.idleAfter = idleAfter }
        func sleep(_ seconds: TimeInterval) async {
            slept += 1
            if let idleAfter, slept >= idleAfter { state = .idle }
        }
    }

    // F1 — the relaunch does not go ahead while the controller records or
    // transcribes: waitForIdle returns only after the state turned idle.
    // Mutation: InstallTermination.waitForIdle, `while state() != .idle` -> `while false` -> RED.
    func testTheWaitEndsOnlyWhenTheDictationIsIdle() async {
        for busy in [DictationState.recording, .transcribing] {
            let dictation = Dictation(busy, idleAfter: 3)
            let result = await InstallTermination.waitForIdle(state: { dictation.state },
                                                              timeout: 120, interval: 0.5, sleep: dictation.sleep)
            XCTAssertEqual(result, .idle)
            XCTAssertEqual(dictation.slept, 3, "\(busy): returned before the dictation was idle")
        }
    }

    func testAnIdleControllerDoesNotWait() async {
        let dictation = Dictation(.idle, idleAfter: nil)
        let result = await InstallTermination.waitForIdle(state: { dictation.state }, sleep: dictation.sleep)
        XCTAssertEqual(result, .idle)
        XCTAssertEqual(dictation.slept, 0)
    }

    // Bounded: a dictation that never ends does not hold the install for good.
    // Mutation: drop the `waited >= timeout` return -> the test never returns (RED by timeout).
    func testAStuckDictationIsWaitedForTheTimeoutThenGivenUp() async {
        let dictation = Dictation(.transcribing, idleAfter: nil)
        let result = await InstallTermination.waitForIdle(state: { dictation.state }, sleep: dictation.sleep)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(Double(dictation.slept) * InstallTermination.pollInterval, InstallTermination.idleTimeout)
        XCTAssertEqual(InstallTermination.idleTimeout, 120)
    }

    // The installer's SIGTERM (install-app.sh) while a dictation runs is left to
    // the relaunch; a plain kill, or an install with nothing dictating, ends the app.
    func testSigtermIsDeferredOnlyForAnInstallDuringADictation() {
        XCTAssertEqual(InstallTermination.sigterm(installing: true, dictation: .recording), .leaveToRelaunch)
        XCTAssertEqual(InstallTermination.sigterm(installing: true, dictation: .transcribing), .leaveToRelaunch)
        XCTAssertEqual(InstallTermination.sigterm(installing: true, dictation: .idle), .terminate)
        XCTAssertEqual(InstallTermination.sigterm(installing: false, dictation: .recording), .terminate)
        XCTAssertEqual(InstallTermination.sigterm(installing: false, dictation: .idle), .terminate)
    }

    // #198.3 — a wake within ten minutes of the last attempt starts no check.
    // Mutation: AutoUpdateSchedule.wakeCheckAllowed, `return true` for every input -> RED.
    func testAWakeWithinTenMinutesOfTheLastAttemptIsSkipped() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AutoUpdateSchedule.wakeCheckAllowed(now: t, lastAttempt: nil))
        XCTAssertFalse(AutoUpdateSchedule.wakeCheckAllowed(now: t.addingTimeInterval(1), lastAttempt: t))
        XCTAssertFalse(AutoUpdateSchedule.wakeCheckAllowed(now: t.addingTimeInterval(599), lastAttempt: t))
        XCTAssertTrue(AutoUpdateSchedule.wakeCheckAllowed(now: t.addingTimeInterval(600), lastAttempt: t))
        XCTAssertTrue(AutoUpdateSchedule.wakeCheckAllowed(now: t.addingTimeInterval(-5), lastAttempt: t), "a clock moved back must not block")
    }
}

/// AppDelegate wiring the unit tests cannot reach, gated by reading the sources.
final class InstallTerminationWiringTests: XCTestCase {
    private func body(_ signature: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("AppDelegate.swift: `\(signature)` not found — the wiring guard has nothing to check"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    // F1 (call site) — mutation: delete the `InstallTermination.waitForIdle(` call in
    // relaunch(), or move `NSApp.terminate(nil)` / `relaunch.run()` above it -> RED.
    func testRelaunchWaitsForTheDictationBeforeItOpensTheNewCopyAndTerminates() {
        let relaunch = body("private func relaunch() async {")
        guard let wait = relaunch.range(of: "InstallTermination.waitForIdle(state: { [unowned self] in self.controller.state })"),
              let open = relaunch.range(of: "relaunch.run()"),
              let terminate = relaunch.range(of: "NSApp.terminate(nil)")
        else { return XCTFail("relaunch() lost the idle wait, the open or the terminate") }
        XCTAssertLessThan(wait.lowerBound, open.lowerBound, "the new copy is opened before the dictation is idle")
        XCTAssertLessThan(wait.lowerBound, terminate.lowerBound, "the app is terminated before the dictation is idle")
        XCTAssertTrue(relaunch.contains(".timedOut") && relaunch.contains(".error("),
                      "a wait that gave up must be logged at error level")
    }

    // Both ways an install ends in relaunch() — the installer's success and the
    // handshake — go through the waiting one; nothing in installUpdate terminates directly.
    // Mutation: call `NSApp.terminate(nil)` in installUpdate, or drop its `await` -> RED.
    func testTheInstallEndsThroughTheWaitingRelaunchOnly() {
        let install = body("private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {")
        XCTAssertTrue(install.contains("await relaunch()"), "installUpdate does not end through the waiting relaunch")
        XCTAssertFalse(install.contains("NSApp.terminate"), "installUpdate terminates the app directly")
        guard let done = install.range(of: "updateInstalling = false"), let relaunch = install.range(of: "await relaunch()") else {
            return XCTFail("installUpdate lost its updateInstalling reset or the relaunch")
        }
        XCTAssertLessThan(done.lowerBound, relaunch.lowerBound,
                          "updateInstalling is reset on the success path too: a second install or a handshake action could start during the wait")
        XCTAssertEqual(install.components(separatedBy: "updateInstalling = false").count - 1, 1)
    }

    // Mutation: put `term.setEventHandler { NSApp.terminate(nil) }` back -> RED
    // (install-app.sh's SIGTERM ends a dictation).
    func testTheSigtermHandlerLeavesAnInstallDuringADictationToTheRelaunch() {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let handler = source.range(of: "term.setEventHandler {"),
              let resume = source.range(of: "term.resume()", range: handler.upperBound..<source.endIndex)
        else { return XCTFail("the SIGTERM handler is gone") }
        let text = source[handler.lowerBound..<resume.lowerBound]
        guard let rule = text.range(of: "InstallTermination.sigterm(installing: self.updateInstalling"),
              let terminate = text.range(of: "NSApp.terminate(nil)")
        else { return XCTFail("the SIGTERM handler does not consult InstallTermination") }
        XCTAssertLessThan(rule.lowerBound, terminate.lowerBound)
        XCTAssertTrue(text.contains(".leaveToRelaunch { return }"))
    }

    // #198.3 call site — mutation: call `self?.backgroundUpdateCheck()` unguarded in the
    // wake observer, or drop the `lastAutoUpdateAttempt = Date()` stamp -> RED.
    func testTheWakeCheckIsDebouncedAndTheAttemptIsStamped() {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let wake = source.range(of: "NSWorkspace.didWakeNotification"),
              let armed = source.range(of: "startAutoUpdateChecks()", range: wake.upperBound..<source.endIndex)
        else { return XCTFail("the wake observer is gone") }
        let observer = String(source[wake.lowerBound..<armed.lowerBound])
        guard let allowed = observer.range(of: "AutoUpdateSchedule.wakeCheckAllowed(now: Date(), lastAttempt: self.lastAutoUpdateAttempt)"),
              let check = observer.range(of: "self.backgroundUpdateCheck()")
        else { return XCTFail("the wake observer does not debounce the check") }
        XCTAssertLessThan(allowed.lowerBound, check.lowerBound)
        let background = body("private func backgroundUpdateCheck() {")
        guard let running = background.range(of: "autoUpdateRunning = true"),
              let stamp = background.range(of: "lastAutoUpdateAttempt = Date()") else {
            return XCTFail("backgroundUpdateCheck does not stamp the attempt")
        }
        XCTAssertLessThan(running.lowerBound, stamp.lowerBound)
    }
}
