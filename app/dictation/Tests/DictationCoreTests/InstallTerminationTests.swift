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
        XCTAssertEqual(InstallTermination.idleTimeout, 600, "toggle-mode recordings can be long")
    }

    // MARK: the detached waiter that opens the new copy after this process is gone

    // The waiter gets this process's pid and the bundle path as separate argv
    // entries after the script, never inside it: a path with spaces, quotes or
    // `$(...)` stays one inert argument. The logger is an argv entry too — only
    // the tag and the bookkeeping numbers are in the script, no user content.
    // Mutation: InstallTermination.openAfterExit, interpolate the path into the
    // script string -> RED.
    func testTheWaiterGetsThePidAndThePathAsSeparateArguments() {
        let path = "/Users/me/My Apps/Ox\"Say $(touch pwned).app"
        let argv = InstallTermination.openAfterExit(pid: 4242, bundlePath: path)
        XCTAssertEqual(argv[0], "/bin/sh")
        XCTAssertEqual(argv[1], "-c")
        XCTAssertEqual(Array(argv[3...]), ["sh", "4242", path, "/usr/bin/open", "30", "/usr/bin/logger"])
        XCTAssertFalse(argv[2].contains(path) || argv[2].contains("4242"), "the arguments are interpolated into the script")
        XCTAssertTrue(argv[2].contains("kill -0 \"$1\""), "the script does not wait for the pid")
        XCTAssertTrue(argv[2].contains(#""$3" "$2""#), "open gets the path alone — no -n while the old copy may still be alive")
        XCTAssertTrue(argv[2].contains(#""$5" -t ox-say-dictation"#), "the failures do not reach the unified log")
        XCTAssertFalse(argv[2].contains("/usr/bin/logger"), "the logger path must stay an argv entry")
    }

    /// Runs the waiter for `pid` with an `open` stub that records its arguments
    /// and a `logger` stub that records each call, one line per invocation.
    private final class WaiterRig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-waiter-\(UUID().uuidString)")
        var opened: URL { dir.appendingPathComponent("opened") }
        var openStub: URL { dir.appendingPathComponent("open-stub") }
        var logged: URL { dir.appendingPathComponent("logged") }
        var loggerStub: URL { dir.appendingPathComponent("logger-stub") }
        init() throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\nprintf '%s' \"$*\" > '\(dir.path)/opened'\n".write(to: openStub, atomically: true, encoding: .utf8)
            try "#!/bin/sh\nprintf '%s\n' \"$*\" >> '\(dir.path)/logged'\n".write(to: loggerStub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openStub.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loggerStub.path)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: dir) }
        func start(_ argv: [String]) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            try p.run()
            return p
        }
        func sleeper(seconds: Int) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["\(seconds)"]
            try p.run()
            return p
        }
        func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
    }

    // The real script, run for real: `open` fires only after the old pid exited.
    // Mutation: InstallTermination.openAfterExit, drop the `while kill -0 ...` loop
    // -> RED (open fires while the old process is still alive).
    func testTheWaiterOpensTheBundleOnlyAfterTheOldProcessExited() async throws {
        let rig = try WaiterRig()
        defer { rig.cleanUp() }
        let old = try rig.sleeper(seconds: 2)
        defer { if old.isRunning { old.terminate() } }
        let waiter = try rig.start(InstallTermination.openAfterExit(pid: old.processIdentifier,
                                                                    bundlePath: "/tmp/My App.app", open: rig.openStub.path,
                                                                    logger: rig.loggerStub.path))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(old.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.opened.path),
                       "open fired while the old process was still alive: two instances would fight over the hotkey")
        let fired = await rig.waitUntil(6) { FileManager.default.fileExists(atPath: rig.opened.path) }
        XCTAssertTrue(fired, "open never fired after the old process exited")
        XCTAssertFalse(old.isRunning)
        XCTAssertEqual(try? String(contentsOf: rig.opened, encoding: .utf8), "/tmp/My App.app", "open got a different path, or -n")
        waiter.waitUntilExit()
        XCTAssertEqual(waiter.terminationStatus, 0)
    }

    // Bounded: a process that never exits does not leave a waiter behind for good,
    // and nothing is opened over it.
    // Mutation: drop the `[ "$n" -ge ... ] && exit 1` line -> RED (the waiter outlives the timeout).
    func testTheWaiterGivesUpWithoutOpeningWhenTheOldProcessStays() async throws {
        let rig = try WaiterRig()
        defer { rig.cleanUp() }
        let old = try rig.sleeper(seconds: 8)
        defer { if old.isRunning { old.terminate() } }
        let waiter = try rig.start(InstallTermination.openAfterExit(pid: old.processIdentifier, bundlePath: "/tmp/x.app",
                                                                    open: rig.openStub.path, timeout: 1,
                                                                    logger: rig.loggerStub.path))
        let gaveUp = await rig.waitUntil(4) { !waiter.isRunning }
        XCTAssertTrue(gaveUp, "the waiter is still waiting after its timeout")
        if waiter.isRunning { waiter.terminate() } else { XCTAssertNotEqual(waiter.terminationStatus, 0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.opened.path), "opened over a live process")
    }

    // #213.2 — the waiter's streams go to /dev/null, so a give-up that logs
    // nothing is a relaunch that silently never happened.
    // Mutation: InstallTermination.openAfterExit, drop the logger call on the
    // give-up path -> RED (nothing lands in `logged`).
    func testTheGiveUpIsLogged() async throws {
        let rig = try WaiterRig()
        defer { rig.cleanUp() }
        let old = try rig.sleeper(seconds: 8)
        defer { if old.isRunning { old.terminate() } }
        let waiter = try rig.start(InstallTermination.openAfterExit(pid: old.processIdentifier, bundlePath: "/tmp/x.app",
                                                                    open: rig.openStub.path, timeout: 1,
                                                                    logger: rig.loggerStub.path))
        let gaveUp = await rig.waitUntil(4) { !waiter.isRunning }
        XCTAssertTrue(gaveUp, "the waiter is still waiting after its timeout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.opened.path), "opened over a live process")
        let logged = (try? String(contentsOf: rig.logged, encoding: .utf8)) ?? ""
        XCTAssertTrue(logged.contains("-t ox-say-dictation"), "the give-up was not logged under the app tag")
        XCTAssertTrue(logged.contains("still alive"), "the log line must say the pid never exited: \(logged)")
    }

    // The other silent failure: `open` itself answers non-zero.
    // Mutation: InstallTermination.openAfterExit, drop the open-failure logger
    // call -> RED.
    func testAFailedOpenIsLoggedAndKeepsItsStatus() async throws {
        let rig = try WaiterRig()
        defer { rig.cleanUp() }
        let failing = rig.dir.appendingPathComponent("open-fails")
        try "#!/bin/sh\nexit 3\n".write(to: failing, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
        let dead = try rig.sleeper(seconds: 0)
        dead.waitUntilExit()
        let waiter = try rig.start(InstallTermination.openAfterExit(pid: dead.processIdentifier, bundlePath: "/tmp/x.app",
                                                                    open: failing.path, timeout: 5,
                                                                    logger: rig.loggerStub.path))
        waiter.waitUntilExit()
        XCTAssertEqual(waiter.terminationStatus, 3, "the waiter ends on open's status")
        let logged = (try? String(contentsOf: rig.logged, encoding: .utf8)) ?? ""
        XCTAssertTrue(logged.contains("-t ox-say-dictation"), "the failed open was not logged under the app tag")
        XCTAssertTrue(logged.contains("open exited 3"), "the log must carry open's failure: \(logged)")
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
    // relaunch(), or move `NSApp.terminate(nil)` / `waiter.run()` above it -> RED.
    func testRelaunchWaitsForTheDictationBeforeItSchedulesTheNewCopyAndTerminates() {
        let relaunch = body("@MainActor @discardableResult private func relaunch() async -> Bool {")
        guard let wait = relaunch.range(of: "InstallTermination.waitForIdle(state: { [unowned self] in self.controller.state })"),
              let schedule = relaunch.range(of: "try waiter.run()"),
              let terminate = relaunch.range(of: "NSApp.terminate(nil)")
        else { return XCTFail("relaunch() lost the idle wait, the waiter or the terminate") }
        XCTAssertLessThan(wait.lowerBound, schedule.lowerBound, "the new copy is scheduled before the dictation is idle")
        XCTAssertLessThan(schedule.lowerBound, terminate.lowerBound, "the app terminates before the waiter that reopens it runs")
        XCTAssertTrue(relaunch.contains(".timedOut") && relaunch.contains("log.error("),
                      "a wait that gave up must be logged at error level")
    }

    // The new copy opens only after THIS process exited (the old one holds the
    // exclusive hotkey): through the detached waiter with this pid and bundle
    // path, never `open -n` straight from the running app. A waiter that cannot
    // start leaves the app running.
    // Mutation: relaunch() runs `/usr/bin/open -n` itself, or terminates in the
    // catch branch, or passes another pid -> RED.
    func testRelaunchOpensTheNewCopyOnlyThroughTheWaiterAndSurvivesItsFailure() {
        let relaunch = body("@MainActor @discardableResult private func relaunch() async -> Bool {")
        XCTAssertTrue(relaunch.contains("InstallTermination.openAfterExit(pid: ProcessInfo.processInfo.processIdentifier,"),
                      "the waiter is not given this process's pid")
        XCTAssertTrue(relaunch.contains("bundlePath: InstalledApp.bundleURL(running: Bundle.main.bundleURL).path)"), "the waiter is not given the installed bundle's path")
        XCTAssertFalse(relaunch.contains("/usr/bin/open") || relaunch.contains("\"-n\""),
                       "relaunch() opens the new copy itself while this process still holds the hotkey")
        guard let `catch` = relaunch.range(of: "} catch {"), let terminate = relaunch.range(of: "NSApp.terminate(nil)") else {
            return XCTFail("relaunch() lost its catch branch or the terminate")
        }
        let failure = relaunch[`catch`.lowerBound..<terminate.lowerBound]
        XCTAssertTrue(failure.contains("log.error(") && failure.contains("return false"),
                      "a waiter that could not start must be logged at error level and leave the app running")
    }

    // Both ways an install ends in relaunch() — the installer's success and the
    // handshake — go through the waiting one; nothing in installUpdate terminates
    // directly, and `updateInstalling` is reset ONLY on the failure paths: on
    // success it stays set through the relaunch wait, so a second install or a
    // handshake action cannot start meanwhile.
    // Mutations: call `NSApp.terminate(nil)` in installUpdate; or restore the
    // unconditional `updateInstalling = false; studio.render()` before
    // `if let failure` -> RED.
    func testTheInstallEndsThroughTheWaitingRelaunchAndResetsOnlyOnFailure() {
        let install = body("private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {")
        XCTAssertTrue(install.contains("await relaunch()"), "installUpdate does not end through the waiting relaunch")
        XCTAssertFalse(install.contains("NSApp.terminate"), "installUpdate terminates the app directly")
        guard let failure = install.range(of: "if let failure {"), let relaunch = install.range(of: "await relaunch()") else {
            return XCTFail("installUpdate lost its failure branch or the relaunch")
        }
        XCTAssertLessThan(failure.lowerBound, relaunch.lowerBound)
        // The failure block runs to the `return` that ends it.
        guard let failureEnd = install.range(of: "return\n            }\n", range: failure.upperBound..<install.endIndex) else {
            return XCTFail("installUpdate's failure block changed shape")
        }
        let beforeFailure = install[install.startIndex..<failure.lowerBound]
        for reset in ["updateInstalling = false", "endInstall()"] {
            XCTAssertFalse(beforeFailure.contains(reset),
                           "`\(reset)` runs before the failure check: the success path resets updateInstalling too")
        }
        XCTAssertTrue(install[failure.lowerBound..<failureEnd.upperBound].contains("endInstall()"),
                      "the failure path does not end the install")
        // After the failure block the one reset is a relaunch that could not start.
        let afterFailure = install[failureEnd.upperBound...]
        XCTAssertFalse(afterFailure.contains("updateInstalling = false"), "a bare reset on the success path")
        guard let relaunchGuard = afterFailure.range(of: "guard await relaunch() else {") else {
            return XCTFail("the success path ignores a relaunch that could not start")
        }
        XCTAssertEqual(afterFailure.components(separatedBy: "endInstall()").count - 1, 1)
        XCTAssertTrue(afterFailure[relaunchGuard.upperBound...].prefix(80).contains("endInstall()"))
        let end = body("private func endInstall() {")
        XCTAssertTrue(end.contains("updateInstalling = false") && end.contains("studio.render()"))
    }

    // A SIGTERM keeps meaning "end now": logout, shutdown and `kill` are not deferred.
    // Mutation: make the handler wait or return when an install/dictation runs -> RED.
    func testTheSigtermHandlerStillTerminatesAtOnce() {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        XCTAssertTrue(source.contains("term.setEventHandler { NSApp.terminate(nil) }"),
                      "the SIGTERM handler does more than terminate")
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
