import XCTest
@testable import DictationCore

/// #129 — the tccutil reset runs off the main thread; here the process is a
/// fake, so nothing real is ever reset.
final class AccessibilityRepairRunTests: XCTestCase {
    private final class FakeLauncher {
        var launched: [[String]] = []
        var exits: [(Int32) -> Void] = []
        var throwOnLaunch = false
        /// When set, terminate() makes the fake process exit with this status
        /// (SIGTERM = 15); nil is a process that ignores the signal.
        var exitOnTerminate: Int32? = 15
        var terminations = 0
        struct Boom: Error {}
        func launch(_ arguments: [String], _ onExit: @escaping (Int32) -> Void) throws -> () -> Void {
            if throwOnLaunch { throw Boom() }
            launched.append(arguments)
            exits.append(onExit)
            return { [unowned self] in
                self.terminations += 1
                if let status = self.exitOnTerminate { onExit(status) }
            }
        }
    }

    /// A clock the test drives by hand.
    private final class FakeClock {
        var scheduled: [(delay: TimeInterval, block: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) { scheduled.append((delay, block)) }
    }

    private let id = "io.github.anatolykoptev.ox-say.dictation"

    /// Starting returns at once with the process still running; the result
    /// arrives from the exit callback, never from a wait.
    /// Mutation: call completion inside start() instead of the exit handler -> RED.
    func testStartDoesNotWaitForTheProcess() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) }), .started)
        XCTAssertEqual(fake.launched, [["reset", "Accessibility", id]])
        XCTAssertTrue(run.isRunning)
        XCTAssertTrue(results.isEmpty, "the result must wait for the process to exit")
        fake.exits[0](0)
        XCTAssertEqual(results, [true])
        XCTAssertFalse(run.isRunning)
    }

    /// A second click while the first reset runs starts nothing.
    /// Mutation: drop the isRunning guard in start() -> RED.
    func testASecondStartWhileRunningIsRefused() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { _ in })
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { _ in }), .busy)
        XCTAssertEqual(fake.launched.count, 1)
    }

    /// A non-zero exit is a failure, and the run is free again afterwards.
    func testNonZeroExitFailsAndFreesTheRun() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) })
        fake.exits[0](1)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { _ in }), .started)
    }

    /// A launch that throws never leaves the run "busy" for good.
    func testALaunchFailureFreesTheRun() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        fake.throwOnLaunch = true
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { _ in }), .launchFailed)
        XCTAssertFalse(run.isRunning)
    }

    /// No usable bundle id: nothing is launched.
    func testNoBundleIDLaunchesNothing() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        XCTAssertEqual(run.start(bundleID: " ", launch: fake.launch, schedule: clock.schedule, completion: { _ in }), .unavailable)
        XCTAssertTrue(fake.launched.isEmpty)
    }

    /// A tccutil that never returns (a stuck tccd) is terminated after the
    /// timeout, so the exit path runs and the caller gets a failure instead of
    /// a menu row greyed for the session. 10 s: tccutil answers in well under
    /// a second, so 10 s is long past slow and still short enough that the
    /// user is not left with a dead row.
    /// Mutation: delete the `terminate()` call in AccessibilityRepairRun's
    /// timeout block -> RED.
    func testAHungProcessIsTerminatedAfterTheTimeoutAndFails() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) })
        XCTAssertEqual(clock.scheduled.first?.delay, AccessibilityRepairRun.timeoutSeconds)
        XCTAssertEqual(AccessibilityRepairRun.timeoutSeconds, 10)
        XCTAssertEqual(fake.terminations, 0, "nothing is killed before the timeout")
        clock.scheduled[0].block()
        XCTAssertEqual(fake.terminations, 1)
        XCTAssertEqual(results, [false], "the termination path reports a failure")
        XCTAssertFalse(run.isRunning)
    }

    /// A process that ignores the signal still frees the run after a grace
    /// period.
    /// Mutation: drop the grace block's completion -> RED.
    func testAProcessThatIgnoresTheTerminationStillFreesTheRun() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        fake.exitOnTerminate = nil
        var results: [Bool] = []
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) })
        clock.scheduled[0].block()
        XCTAssertTrue(run.isRunning, "still waiting for the grace period")
        XCTAssertEqual(clock.scheduled.count, 2)
        clock.scheduled[1].block()
        XCTAssertEqual(results, [false])
        XCTAssertFalse(run.isRunning)
        fake.exits[0](15)
        XCTAssertEqual(results, [false], "a late exit does not complete twice")
    }

    /// An exit before the timeout disarms it: the late block neither kills a
    /// finished process nor completes twice, nor touches the NEXT run.
    func testAnExitBeforeTheTimeoutDisarmsIt() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) })
        fake.exits[0](0)
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { results.append($0) })
        clock.scheduled[0].block()
        XCTAssertEqual(fake.terminations, 0, "the first run's timeout must not kill the second run")
        XCTAssertEqual(results, [true])
        XCTAssertTrue(run.isRunning)
    }

    /// A process that reports its exit twice completes once.
    func testADoubleExitCompletesOnce() {
        let fake = FakeLauncher(); let clock = FakeClock(); let run = AccessibilityRepairRun()
        var count = 0
        _ = run.start(bundleID: id, launch: fake.launch, schedule: clock.schedule, completion: { _ in count += 1 })
        fake.exits[0](0); fake.exits[0](0)
        XCTAssertEqual(count, 1)
    }
}

/// #129 — the wiring around the runner: no blocking wait on main, the item
/// greyed while the reset runs, one UI after it, a separator under the top rows.
final class AccessibilityRepairWiringTests: XCTestCase {
    private static var source: String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private func body(_ signature: String) -> String {
        let s = Self.source
        guard let start = s.range(of: signature),
              let end = s.range(of: "\n    }\n", range: start.upperBound..<s.endIndex)
        else { XCTFail("\(signature) not found"); return "" }
        return String(s[start.lowerBound..<end.upperBound])
    }

    /// Mutation: re-add `reset.waitUntilExit()` to allowPasting -> RED.
    func testAllowPastingNeverBlocksTheMainThread() {
        let b = body("@objc private func allowPasting() {")
        XCTAssertFalse(b.contains("waitUntilExit"), "tccutil is awaited on the main thread")
        XCTAssertTrue(b.contains("repairRun.start("), "the reset must go through AccessibilityRepairRun")
        XCTAssertTrue(b.contains("allowPastingItem.isEnabled = false"), "the item stays clickable while the reset runs")
        XCTAssertTrue(b.contains("allowPastingItem.isEnabled = true"), "the item is never re-enabled")
    }

    /// After a successful reset the trust prompt is raised AND the pane is
    /// opened: the prompt is not guaranteed to show again for an app that is
    /// already listed, and a silent click is worse than two windows.
    /// Mutation: delete `openAccessibilitySettings()` from allowPasting -> RED.
    func testAllowPastingRaisesThePromptAndOpensThePane() {
        let b = body("@objc private func allowPasting() {")
        XCTAssertTrue(b.contains("AXIsProcessTrustedWithOptions(prompt)"))
        XCTAssertTrue(b.contains("self.openAccessibilitySettings()"))
    }

    /// Mutation: delete the separator before the status line in buildMenu -> RED.
    func testASeparatorSitsUnderTheTopRows() {
        let b = body("private func buildMenu() {")
        guard let sep = b.range(of: "menu.addItem(.separator())"),
              let status = b.range(of: "menu.addItem(statusLine)") else { return XCTFail("buildMenu changed shape") }
        XCTAssertLessThan(sep.lowerBound, status.lowerBound, "the top rows run straight into the status line")
    }

    /// The terminate of a hung reset must not race the process's own exit: `Process.terminate()` raises when the
    /// process ended between the check and the call, so the app sends a signal under the termination handler's lock.
    /// Mutation: AppDelegate.allowPasting, `ended.signalIfRunning(pid, SIGTERM)` -> `if reset.isRunning { reset.terminate() }` -> RED.
    func testTheTerminateOfAHungResetCannotRaceItsExit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"), encoding: .utf8))
        XCTAssertTrue(source.contains("return { ended.signalIfRunning(pid, SIGTERM) }"))
        XCTAssertFalse(source.contains("reset.terminate()"), "Process.terminate() raises on a process that already ended")
        XCTAssertTrue(source.contains("ended.mark()\n                let status = process.terminationStatus"), "the handler marks the exit before reporting it")
        XCTAssertTrue(source.contains("lock.withLock { if !ended { _ = kill(pid, signal) } }"), "the signal is sent under the lock")
    }
}
