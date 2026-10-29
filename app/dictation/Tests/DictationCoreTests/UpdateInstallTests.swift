import XCTest
@testable import DictationCore

private let enText = ShippedStrings.localizer("en")
private let ruText = ShippedStrings.localizer("ru")

final class UpdateInstallTests: XCTestCase {
    func testDownloadIsAStandaloneCurlWithItsOwnExitStatus() {
        let argv = UpdateInstaller.downloadCommand(to: "/tmp/x.sh")
        XCTAssertEqual(argv.first, "/usr/bin/curl")
        XCTAssertTrue(argv[1].contains("f"), "curl must fail on HTTP errors")
        XCTAssertEqual(Array(argv.suffix(3)), ["-o", "/tmp/x.sh", UpdateInstaller.scriptURL])
    }

    func testNoCommandIsAShellPipeline() {
        let all = UpdateInstaller.downloadCommand(to: "/tmp/x.sh") + UpdateInstaller.installCommand(script: "/tmp/x.sh", tag: "v1.2.3")
        for arg in all {
            XCTAssertFalse(arg.contains("|"), "a pipe hides curl's exit status: \(arg)")
        }
        XCTAssertFalse(all.contains("-c"), "no sh -c script string")
    }

    func testInstallRunsTheFileNotStdinAndPinsTheTag() {
        XCTAssertEqual(UpdateInstaller.installCommand(script: "/tmp/x.sh", tag: "v0.1.21"),
                       ["/bin/sh", "/tmp/x.sh", "--version", "v0.1.21"])
    }

    /// Mutation: UpdateInstall.swift command(kind:), the `.studioVoice` branch
    /// without its environment entry (`environment: [:]`) -> RED.
    func testStudioVoiceInstallIsPinnedToTheTagAndSwitchesTheModelOn() {
        let command = UpdateInstaller.command(kind: .studioVoice, script: "/tmp/x.sh", tag: UpdateInstaller.tag(forVersion: "0.1.21"))
        XCTAssertEqual(command.argv, ["/bin/sh", "/tmp/x.sh", "--version", "v0.1.21"])
        XCTAssertEqual(command.environment["OX_SAY_WITH_VOXCPM2"], "1")
    }

    func testPlainUpdateDoesNotDownloadTheStudioModel() {
        let command = UpdateInstaller.command(kind: .update, script: "/tmp/x.sh", tag: "v0.1.22")
        XCTAssertEqual(command.argv, ["/bin/sh", "/tmp/x.sh", "--version", "v0.1.22"])
        XCTAssertNil(command.environment["OX_SAY_WITH_VOXCPM2"])
        XCTAssertEqual(command.environment, [UpdateInstaller.appRelaunchesVariable: "1"])
    }

    // #198.1 — every install the app starts tells the installer that the app
    // relaunches itself, so install-app.sh does not kill a dictation.
    // Mutation: UpdateInstall.swift command(kind:), drop `appRelaunchesVariable` from
    // either branch -> RED.
    func testEveryInstallTheAppStartsCarriesTheRelaunchVariable() {
        for kind in [UpdateInstaller.Kind.update, .studioVoice] {
            let command = UpdateInstaller.command(kind: kind, script: "/tmp/x.sh", tag: "v0.1.22")
            XCTAssertEqual(command.environment["OX_SAY_APP_RELAUNCHES"], "1", "\(kind): the installer would stop the running app")
            XCTAssertEqual(command.launchEnvironment(base: [:])["OX_SAY_APP_RELAUNCHES"], "1")
        }
    }

    /// The name install-app.sh reads is the name the app sets.
    /// Mutation: rename the variable in install-app.sh (or in UpdateInstaller) -> RED.
    func testTheInstallerScriptReadsTheVariableTheAppSets() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("install-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("${\(UpdateInstaller.appRelaunchesVariable):-0}\" = 1"),
                      "install-app.sh does not read \(UpdateInstaller.appRelaunchesVariable)")
    }

    /// AppDelegate.installUpdate is the one door every install goes through
    /// (offered row, manual confirm, Repair, studio voice) and it hands its kind
    /// to UpdateInstaller.run, which builds the command with the variable.
    /// Mutation: AppDelegate.installUpdate runs a hand-built command instead -> RED.
    func testInstallUpdateRunsTheInstallerThroughUpdateInstallerRun() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        guard let start = source.range(of: "private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return XCTFail("installUpdate not found") }
        let body = source[start.lowerBound..<end.upperBound]
        XCTAssertTrue(body.contains("UpdateInstaller.run(kind: kind, tag: tag"), "installUpdate bypasses UpdateInstaller.run")
        XCTAssertFalse(body.contains("Process()"), "installUpdate starts its own process, without the relaunch variable")
    }

    private func appDelegateBody(_ signature: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("`\(signature)` not found"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// #213.3 — a dictation owns the pill, and an install can start during it:
    /// the confirm alert and the Repair/Studio rows are not idle-gated. If the
    /// pill show is not guarded, "Installing…" replaces the recording's look
    /// and stays up through the whole relaunch wait after the install ends.
    /// Mutation: drop `if controller.state == .idle` around the pill show in
    /// installUpdate -> RED.
    func testTheInstallPillIsNotShownOverARunningDictation() throws {
        let body = try appDelegateBody("private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {")
        guard let idle = body.range(of: "if controller.state == .idle { showInstallPill() }"),
              let text = body.range(of: "installPillText = ") else {
            return XCTFail("installUpdate lost the idle guard or the pill text")
        }
        XCTAssertLessThan(text.lowerBound, idle.lowerBound, "the pill text is set after the pill is shown")
        XCTAssertFalse(body.contains("overlay.showWorking()"), "installUpdate shows the pill itself, past the idle guard")
    }

    /// The helper both call sites share: it shows the install's own pill and
    /// captures the owner of what it just showed.
    func testTheInstallPillHelperShowsThePillAndCapturesItsOwner() throws {
        let body = try appDelegateBody("private func showInstallPill() {")
        guard let show = body.range(of: "overlay.showWorking()"),
              let text = body.range(of: "overlay.setWorkingText(text)"),
              let owner = body.range(of: "beginPill(&installPill)") else {
            return XCTFail("showInstallPill lost the show, the text or the owner capture")
        }
        XCTAssertTrue(show.lowerBound < text.lowerBound && text.lowerBound < owner.lowerBound,
                      "the owner must be the pill that was just shown")
    }

    /// An install that started during a dictation shows no pill then. When the
    /// dictation ends the install is still running, so `show(.idle)` puts the
    /// pill up, after `overlay.finish()` cleared the dictation's and before a
    /// released notice may replace it. The text is dropped with the install.
    /// Mutations: delete the `if updateInstalling { showInstallPill() }` line in
    /// show(.idle); or drop `installPillText = nil` in endInstall (the pill
    /// would come back after the install ended) -> RED.
    func testTheInstallPillReturnsWhenTheDictationThatHeldItEnds() throws {
        let show = try appDelegateBody("private func show(")
        guard let idle = show.range(of: "case .idle:"),
              let recording = show.range(of: "case .recording:", range: idle.upperBound..<show.endIndex) else {
            return XCTFail("show(.idle) not found")
        }
        // Every anchor is searched inside the `.idle` case only: an earlier
        // `overlay.finish()` or release in another case must not satisfy the order.
        let idleCase = String(show[idle.lowerBound..<recording.lowerBound])
        guard let finish = idleCase.range(of: "overlay.finish()"),
              let pill = idleCase.range(of: "if updateInstalling { showInstallPill() }"),
              let release = idleCase.range(of: "noticeGate.release(state: controller.state)") else {
            return XCTFail("show(.idle) does not bring the install pill back")
        }
        XCTAssertTrue(finish.lowerBound < pill.lowerBound && pill.lowerBound < release.lowerBound,
                      "the install pill must come after overlay.finish() and before the notice release, inside .idle")
        let end = try appDelegateBody("private func endInstall() {")
        XCTAssertTrue(end.contains("installPillText = nil"), "the pill text outlives the install")
    }

    func testLaunchEnvironmentAddsTheCommandsVariablesToTheApps() {
        let command = UpdateInstaller.Command(argv: ["/bin/true"], environment: ["A": "new"])
        XCTAssertEqual(command.launchEnvironment(base: ["A": "old", "B": "kept"]), ["A": "new", "B": "kept"])
    }

    // MARK: the whole install, through a real process

    private struct Rig {
        let dir: URL
        /// A file:// URL of a fake get.sh that records its arguments and the studio switch.
        let source: String
        var env: String { (try? String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)) ?? "<not run>" }
        var relaunch: String { (try? String(contentsOf: dir.appendingPathComponent("relaunch"), encoding: .utf8)) ?? "<not run>" }
        var args: String { (try? String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)) ?? "<not run>" }

        init(script: String? = nil) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-install-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("get.sh")
            let body = script ?? "#!/bin/sh\nprintf '%s' \"$OX_SAY_WITH_VOXCPM2\" > '\(dir.path)/env'\nprintf '%s' \"$OX_SAY_APP_RELAUNCHES\" > '\(dir.path)/relaunch'\nprintf '%s' \"$*\" > '\(dir.path)/args'\n"
            try body.write(to: file, atomically: true, encoding: .utf8)
            source = "file://" + file.path
        }

        func cleanUp() {
            for name in ["get.sh", "env", "relaunch", "args"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The choice between the studio install and the plain update, run for real:
    /// the studio install's process sees the switch, the update's does not. A
    /// regression at either end — the decision or the environment reaching the
    /// process — leaves the studio model un-downloaded with no error.
    /// Mutations: UpdateInstall.swift command(kind:), `.studioVoice` branch uses
    /// `environment: [:]` -> RED; UpdateInstall.swift runProcess, `p.environment =`
    /// line removed -> RED.
    func testTheStudioInstallRunsWithTheSwitchAndTheUpdateWithout() async throws {
        unsetenv(UpdateInstaller.studioVoiceVariable)
        unsetenv(UpdateInstaller.appRelaunchesVariable)
        let studio = try Rig()
        defer { studio.cleanUp() }
        let failure = await UpdateInstaller.run(kind: .studioVoice, tag: "v0.1.21", log: nil,
                                                scriptSource: studio.source,
                                                installedVersion: { "0.1.21" }, daemonVersion: { "v0.1.21" })
        XCTAssertNil(failure)
        XCTAssertEqual(studio.env, "1", "the installer process must get OX_SAY_WITH_VOXCPM2=1")
        XCTAssertEqual(studio.relaunch, "1", "the installer process must get OX_SAY_APP_RELAUNCHES=1")
        XCTAssertEqual(studio.args, "--version v0.1.21")

        let update = try Rig()
        defer { update.cleanUp() }
        let updateFailure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                      scriptSource: update.source,
                                                      installedVersion: { "0.1.22" }, daemonVersion: { "v0.1.22" })
        XCTAssertNil(updateFailure)
        XCTAssertEqual(update.env, "", "a plain update must not download the studio model")
        XCTAssertEqual(update.relaunch, "1", "the installer process must get OX_SAY_APP_RELAUNCHES=1")
        XCTAssertEqual(update.args, "--version v0.1.22")
    }

    func testAnInstallThatLeavesTheOldVersionFails() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        var daemonPolls = 0
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                scriptSource: rig.source,
                                                installedVersion: { "0.1.21" },
                                                daemonVersion: { daemonPolls += 1; return "v0.1.22" })
        XCTAssertEqual(failure, .versionUnchanged(expected: "v0.1.22", found: "0.1.21"))
        XCTAssertEqual(daemonPolls, 0, "a stale bundle fails before one /status poll is spent")
    }

    func testAFailingInstallerOrANonScriptIsReported() async throws {
        let failing = try Rig(script: "#!/bin/sh\nexit 3\n")
        defer { failing.cleanUp() }
        let status = await UpdateInstaller.run(kind: .studioVoice, tag: "v0.1.21", log: nil,
                                               scriptSource: failing.source,
                                               installedVersion: { "0.1.21" }, daemonVersion: { nil })
        XCTAssertEqual(status, .installerFailed(status: 3))

        let html = try Rig(script: "<html>404</html>")
        defer { html.cleanUp() }
        let notScript = await UpdateInstaller.run(kind: .update, tag: "v0.1.21", log: nil,
                                                  scriptSource: html.source,
                                                  installedVersion: { "0.1.21" }, daemonVersion: { nil })
        XCTAssertEqual(notScript, .notAScript)

        let missing = await UpdateInstaller.run(kind: .update, tag: "v0.1.21", log: nil,
                                                scriptSource: "file:///nonexistent/ox-say-get.sh",
                                                installedVersion: { "0.1.21" }, daemonVersion: { nil })
        guard case .downloadFailed? = missing else { return XCTFail("expected a download failure, got \(String(describing: missing))") }
    }

    func testInstalledVersionBecomesItsReleaseTag() {
        XCTAssertEqual(UpdateInstaller.tag(forVersion: "0.1.21"), "v0.1.21")
        XCTAssertEqual(UpdateInstaller.tag(forVersion: "v0.1.21"), "v0.1.21")
    }

    func testScriptCheck() {
        XCTAssertTrue(UpdateInstaller.isScript(head: Data("#!/bin/sh\necho".utf8)))
        XCTAssertFalse(UpdateInstaller.isScript(head: Data()))
        XCTAssertFalse(UpdateInstaller.isScript(head: Data("<html>404".utf8)))
    }

    func testVersionMatchIgnoresTheVPrefix() async {
        let a = await UpdateInstaller.verifyInstalled(version: "0.1.21", daemonVersion: { "v0.1.21" }, target: "v0.1.21",
                                                      checks: 3, interval: 0.001)
        let b = await UpdateInstaller.verifyInstalled(version: "v0.1.21", daemonVersion: { "0.1.21" }, target: "0.1.21",
                                                      checks: 3, interval: 0.001)
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func testUnchangedVersionIsAFailureNamingBothVersions() async {
        let f = await UpdateInstaller.verifyInstalled(version: "0.1.20", daemonVersion: { nil }, target: "v0.1.21")
        XCTAssertEqual(f, .versionUnchanged(expected: "v0.1.21", found: "0.1.20"))
        XCTAssertEqual(f?.message(text: enText), "The version did not change: expected v0.1.21 after the install, found v0.1.20.")
    }

    func testUnreadableInstalledVersionIsAFailure() async {
        let failure = await UpdateInstaller.verifyInstalled(version: nil, daemonVersion: { nil }, target: "v0.1.21")
        XCTAssertEqual(failure, .versionUnchanged(expected: "v0.1.21", found: nil))
    }

    // MARK: verifyInstalled also waits for the daemon

    /// A daemon still restarting when the bundle already matches: the poll
    /// catches it landing on the target. Mutation: the daemonVersion loop in
    /// verifyInstalled deleted (disk check alone) -> RED here and below.
    func testVerifyInstalledWaitsForTheDaemonToReachTheTarget() async {
        var answers = ["v0.1.21", "v0.1.22"]
        let failure = await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: {
            answers.isEmpty ? "v0.1.22" : answers.removeFirst()
        }, target: "v0.1.22", checks: 40, interval: 0.001)
        XCTAssertNil(failure)
    }

    func testAnAnsweringDaemonNeedsNoWait() async {
        var polls = 0
        let failure = await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: {
            polls += 1
            return "v0.1.22"
        }, target: "v0.1.22", checks: 40, interval: 0.001)
        XCTAssertNil(failure)
        XCTAssertEqual(polls, 1, "the daemon answering the target ends the wait on the first poll")
    }

    func testADaemonThatNeverReachesTheTargetIsAFailure() async {
        var polls = 0
        let failure = await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: {
            polls += 1
            return "v0.1.21"
        }, target: "v0.1.22", checks: 3, interval: 0.001)
        XCTAssertEqual(failure, .daemonNotOnVersion(expected: "v0.1.22", found: "v0.1.21"))
        XCTAssertEqual(polls, 3, "bounded: exactly `checks` polls")
        XCTAssertEqual(failure?.message(text: enText),
                       "The ox-say service did not reach v0.1.22 after the install; /status reports v0.1.21.")
    }

    /// A daemon that never answers is the same failure, without a made-up version.
    func testVerifyInstalledReportsAnUnreachableDaemon() async {
        let failure = await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: { nil },
                                                            target: "v0.1.22", checks: 3, interval: 0.001)
        XCTAssertEqual(failure, .daemonNotOnVersion(expected: "v0.1.22", found: nil))
    }

    // MARK: the wait's wall-clock bound

    /// A count both the polling task and the test read, under a lock.
    private final class PollCounter {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    /// Mutation: UpdateInstall.swift verifyInstalled, `guard poll < checks - 1`
    /// deleted -> RED (a pause after the final poll).
    func testThereIsNoPauseAfterTheFinalPoll() async {
        var sleeps = 0
        let failure = await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: { nil },
                                                            target: "v0.1.22", checks: 4, interval: 0.5,
                                                            sleep: { _ in sleeps += 1 })
        XCTAssertEqual(failure, .daemonNotOnVersion(expected: "v0.1.22", found: nil))
        XCTAssertEqual(sleeps, 3, "between polls only: checks - 1")
    }

    /// A cancelled wait stops where it stands, not at the bound.
    /// Mutation: verifyInstalled, `do { try await sleep(interval) } catch { break }`
    /// -> `try? await sleep(interval)` AND the `Task.isCancelled` line deleted -> RED.
    func testACancelledWaitStopsAtOnce() async {
        let polls = PollCounter()
        let started = Date()
        let task = Task { () -> UpdateInstaller.Failure? in
            await UpdateInstaller.verifyInstalled(version: "0.1.22", daemonVersion: { polls.bump(); return nil },
                                                  target: "v0.1.22", checks: 40, interval: 30)
        }
        while polls.count == 0 { await Task.yield() }
        task.cancel()
        let failure = await task.value
        XCTAssertEqual(failure, .daemonNotOnVersion(expected: "v0.1.22", found: nil))
        XCTAssertEqual(polls.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "not 40 x 30 s")
    }

    func testFailureMessages() {
        XCTAssertEqual(UpdateInstaller.Failure.downloadFailed(status: 22).message(text: enText),
                       "Downloading the installer failed (curl exited with status 22).")
        XCTAssertEqual(UpdateInstaller.Failure.installerFailed(status: 1).message(text: enText), "The installer exited with status 1.")
        XCTAssertEqual(UpdateInstaller.Failure.couldNotStart("no such file").message(text: enText), "The installer could not start: no such file.")
    }

    func testCheckIsRefusedWhileInstalling() {
        XCTAssertEqual(UpdateGate.decide(installing: true), .installInProgress)
        XCTAssertEqual(UpdateGate.decide(installing: false), .proceed)
    }
}


// MARK: #135 — the download is bounded, the installed copy is the one read, #221.1 the pill returns

final class UpdateInstallRobustnessTests: XCTestCase {
    private func flag(_ name: String, in argv: [String]) -> Double? {
        guard let i = argv.firstIndex(of: name), argv.indices.contains(i + 1) else { return nil }
        return Double(argv[i + 1])
    }

    func testTheDownloadCarriesACurlConnectAndTotalBound() {
        let argv = UpdateInstaller.downloadCommand(to: "/tmp/x.sh")
        XCTAssertEqual(flag("--connect-timeout", in: argv), UpdateInstaller.downloadConnectTimeout)
        XCTAssertEqual(flag("--max-time", in: argv), UpdateInstaller.downloadMaxTime)
        XCTAssertGreaterThan(UpdateInstaller.downloadBackstop, UpdateInstaller.downloadMaxTime,
                             "the backstop must let curl's own bound fire first")
    }

    /// A download that never exits ends in `.downloadTimedOut`, and the process is killed.
    /// Mutation: UpdateInstall.swift run(), the download `runProcess(download, log: log, timeout: downloadBackstop)`
    /// without `timeout:` -> RED (the fake sleeps 20 s, then the script check fails: not .downloadTimedOut).
    func testADownloadThatNeverExitsEndsInATimeoutFailure() async {
        let started = Date()
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                downloadBackstop: 0.3,
                                                downloadArgv: { _, _ in ["/bin/sleep", "20"] },
                                                installedVersion: { nil }, daemonVersion: { nil })
        XCTAssertEqual(failure, .downloadTimedOut(seconds: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the run waited for the hung process")
        XCTAssertTrue(failure?.message(text: enText).contains("timed out") ?? false, failure?.message(text: enText) ?? "nil")
    }

    /// A downloadable get.sh that passes the script check; the installer under test is injected, so it never runs.
    private struct ScriptRig {
        let dir: URL
        let source: String

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-ceiling-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("get.sh")
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            source = "file://" + file.path
        }

        func cleanUp() { try? FileManager.default.removeItem(at: dir) }
    }

    /// A counted clock and a scripted progress value: each poll moves the clock 60 s and asks `step` for the value, so
    /// "20 minutes without progress" is 20 polls, however fast the test runs. `step(poll)` may also act (open a gate).
    private final class CountedWatch: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var polls = 0
        private var time = 0.0
        let step: (Int) -> UInt64

        init(step: @escaping (Int) -> UInt64) { self.step = step }

        var watch: UpdateInstaller.IdleWatch {
            .init(idleLimit: UpdateInstaller.installerIdleLimit, pollInterval: 0.01,
                  progress: { [self] in
                      lock.lock()
                      polls += 1
                      let n = polls
                      lock.unlock()
                      return step(n)
                  },
                  now: { [self] in
                      lock.lock()
                      defer { lock.unlock() }
                      time += 60
                      return time
                  })
        }
    }

    /// #356: an installer that stalls (no progress for the idle limit) ends in the failure alert instead of holding
    /// `updateInstalling` (and, since #355, the refusal of dictation and read-aloud) until the app is quit.
    /// Mutation: UpdateInstall.swift run(), the install `runProcess(..., log: log, idle: watch)` without `idle:` -> RED
    /// (the fake sleeps 20 s; the run returns after it with nil/.versionUnchanged, not .installerTimedOut).
    func testAnInstallerThatStallsIsEndedAtTheIdleLimitAndFreesDaemonWork() async throws {
        let rig = try ScriptRig()
        defer { rig.cleanUp() }
        let counted = CountedWatch { _ in 7 }
        let started = Date()
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil, scriptSource: rig.source,
                                                installerWatch: counted.watch,
                                                installer: { _, _, _ in .init(argv: ["/bin/sleep", "20"], environment: [:]) },
                                                installedVersion: { "0.1.22" }, daemonVersion: { "v0.1.22" })
        XCTAssertEqual(failure, .installerTimedOut(seconds: UpdateInstaller.installerIdleLimit))
        XCTAssertGreaterThanOrEqual(counted.polls, 20, "ended before the limit of counted minutes without progress")
        XCTAssertLessThanOrEqual(counted.polls, 22)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the run waited for the stalled installer")
        // Any failure makes AppDelegate.installUpdate call endInstall() (pinned in InstallTerminationTests), which clears
        // `updateInstalling`; with it clear, the gate lets dictation and read-aloud start again.
        XCTAssertFalse(UpdateGate.allowsNewDaemonWork(installing: true))
        XCTAssertTrue(UpdateGate.allowsNewDaemonWork(installing: false))
    }

    /// A slow but alive install is never cut: progress for three times the idle limit, then the installer finishes.
    /// Mutation: UpdateInstall.swift IdleWatcher.stalled(), delete `lastChange = t` -> RED (killed at the limit).
    func testAnInstallerThatKeepsProgressingPastTheIdleLimitIsNotKilled() async throws {
        let rig = try ScriptRig()
        defer { rig.cleanUp() }
        let gate = rig.dir.appendingPathComponent("gate")
        let counted = CountedWatch { n in
            if n == 60 { FileManager.default.createFile(atPath: gate.path, contents: Data()) }
            return UInt64(n)
        }
        let script = "while [ ! -e '\(gate.path)' ]; do sleep 0.02; done"
        let failure = await UpdateInstaller.run(kind: .studioVoice, tag: "v0.1.22", log: nil, scriptSource: rig.source,
                                                installerWatch: counted.watch,
                                                installer: { _, _, _ in .init(argv: ["/bin/sh", "-c", script], environment: [:]) },
                                                installedVersion: { "0.1.22" }, daemonVersion: { "v0.1.22" })
        XCTAssertNil(failure, "an install that keeps making progress was ended")
        XCTAssertGreaterThanOrEqual(counted.polls, 60)
    }

    /// The stalled installer is asked to leave first (get.sh's TERM trap removes its temp dirs), its whole tree is gone
    /// and its cleanup has finished BEFORE the run reports the failure: the alert and `endInstall()` never meet a live
    /// installer. The fake's TERM trap takes a second and then writes a marker.
    /// Mutations: UpdateInstall.swift terminateThenKill, the first loop sends SIGKILL instead of SIGTERM -> RED (no marker);
    /// runProcess `expire`, `once.resume(.failure(ProcessTimedOut()))` moved above the terminate call -> RED (no marker yet).
    func testTheStalledInstallerCleansUpBeforeTheFailureIsReported() async throws {
        let rig = try ScriptRig()
        defer { rig.cleanUp() }
        let pidFile = rig.dir.appendingPathComponent("grandchild.pid")
        let marker = rig.dir.appendingPathComponent("cleaned")
        let script = "trap 'sleep 1; echo cleaned > \"\(marker.path)\"; exit 0' TERM; sleep 600 & echo $! > '\(pidFile.path)'; wait"
        let counted = CountedWatch { _ in 7 }
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil, scriptSource: rig.source,
                                                installerWatch: counted.watch,
                                                installer: { _, _, _ in .init(argv: ["/bin/sh", "-c", script], environment: [:]) },
                                                installedVersion: { nil }, daemonVersion: { nil })
        XCTAssertEqual(failure, .installerTimedOut(seconds: UpdateInstaller.installerIdleLimit))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the run reported before the installer's TERM cleanup finished (or it never got TERM)")
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(Int32(text), "the fake installer never recorded its child")
        var alive = true
        for _ in 0..<40 {
            alive = kill(grandchild, 0) == 0
            if !alive { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if alive { _ = kill(grandchild, SIGKILL) }
        XCTAssertFalse(alive, "the installer's child survived")
    }

    /// A process that ignores TERM is killed after the grace, and so is what it started (read again before the KILL).
    /// Mutation: UpdateInstall.swift terminateThenKill, delete the final `SIGKILL` loop -> RED (the run waits out `sleep`).
    func testAnInstallerThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let rig = try ScriptRig()
        defer { rig.cleanUp() }
        let counted = CountedWatch { _ in 7 }
        let pidFile = rig.dir.appendingPathComponent("stubborn.pid")
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; while :; do sleep 0.05; done"
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil, scriptSource: rig.source,
                                                installerWatch: counted.watch,
                                                installer: { _, _, _ in .init(argv: ["/bin/sh", "-c", script], environment: [:]) },
                                                installedVersion: { nil }, daemonVersion: { nil })
        XCTAssertEqual(failure, .installerTimedOut(seconds: UpdateInstaller.installerIdleLimit))
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        var alive = true
        for _ in 0..<40 {
            alive = kill(pid, 0) == 0
            if !alive { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if alive { _ = kill(pid, SIGKILL) }
        XCTAssertFalse(alive, "an installer that ignores TERM survived the grace")
    }

    /// The idle limit outlasts the longest silent stretch the scripts allow: the self-test's three calls of 300 s each.
    /// Mutation: UpdateInstall.swift installerIdleLimit 1200 -> 600 -> RED.
    func testTheIdleLimitOutlastsTheSelfTest() {
        XCTAssertGreaterThan(UpdateInstaller.installerIdleLimit, 3 * 300 + 100)
    }

    /// What counts as progress: the log growing, or the models directory changing. Mutation: installProgress ignores
    /// the models directory (the silent model fetch looks idle) -> RED; ignores the log -> RED.
    func testProgressIsTheLogAndTheModelsDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-progress-\(UUID().uuidString)")
        let models = dir.appendingPathComponent("models/nested")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close(); try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("models")
        let start = UpdateInstaller.installProgress(log: log, models: root)
        try log.write(contentsOf: Data("progress".utf8))
        let afterLog = UpdateInstaller.installProgress(log: log, models: root)
        XCTAssertNotEqual(afterLog, start, "log growth is not progress")
        try Data(repeating: 0, count: 100).write(to: models.appendingPathComponent("m.gguf.part"))
        XCTAssertNotEqual(UpdateInstaller.installProgress(log: log, models: root), afterLog, "a growing .part is not progress")
        XCTAssertEqual(UpdateInstaller.installProgress(log: nil, models: dir.appendingPathComponent("absent")), 0)
        let env = ["OX_SAY_HOME": "/tmp/x"]
        XCTAssertEqual(UpdateInstaller.modelsDirectory(environment: env).path, "/tmp/x/models")
        XCTAssertTrue(UpdateInstaller.modelsDirectory(environment: [:], home: URL(fileURLWithPath: "/Users/u")).path
            .hasSuffix("/Users/u/Library/Application Support/ox-say/models"))
    }

    /// The call site watches by default (a nil watch would leave the installer unbounded).
    /// Mutation: UpdateInstall.swift run(), the default `IdleWatch(idleLimit: installerIdleLimit` -> `.infinity` -> RED.
    func testRunWatchesTheInstallerByDefault() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DictationCore/UpdateInstall.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("installerWatch ?? IdleWatch(idleLimit: installerIdleLimit, pollInterval: progressPollInterval"))
        XCTAssertTrue(source.contains("log: log, idle: watch)"))
    }

    func testACurlThatCannotStartHasItsOwnText() async {
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                downloadArgv: { _, _ in ["/nonexistent/curl"] },
                                                installedVersion: { nil }, daemonVersion: { nil })
        guard case .downloaderCouldNotStart? = failure else { return XCTFail("got \(String(describing: failure))") }
        XCTAssertTrue(failure?.message(text: enText).hasPrefix("The download could not start:") ?? false, failure?.message(text: enText) ?? "nil")
    }

    /// curl's own `--max-time` ends with exit 28 long before the app-side backstop: that is the timed-out sentence, not
    /// "curl exited with status 28". Mutation: UpdateInstall.swift run(), delete the `curlTimedOutStatus` case -> RED.
    func testCurlsOwnTimeoutIsTheTimedOutSentence() async {
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                downloadArgv: { _, _ in ["/bin/sh", "-c", "exit 28"] },
                                                installedVersion: { nil }, daemonVersion: { nil })
        XCTAssertEqual(failure, .downloadTimedOut(seconds: nil))
        // exit 28 is `--max-time` (60 s) AND `--connect-timeout` (15 s): naming either figure is wrong half the time.
        XCTAssertEqual(failure?.message(text: enText), "Downloading the installer timed out.")
        XCTAssertEqual(UpdateInstaller.Failure.downloadTimedOut(seconds: 90).message(text: enText),
                       "Downloading the installer timed out after 90 s.", "the backstop knows its own figure")
        let other = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                              downloadArgv: { _, _ in ["/bin/sh", "-c", "exit 22"] },
                                              installedVersion: { nil }, daemonVersion: { nil })
        XCTAssertEqual(other, .downloadFailed(status: 22), "only 28 is a timeout")
    }

    func testTheScriptHeadReadHasANamedLength() {
        XCTAssertEqual(UpdateInstaller.scriptHeadLength, 2, "`#!` is two bytes")
    }

    // The installed copy, not the running one.
    func testTheInstalledCopyIsReadWhenItExists() {
        let home = URL(fileURLWithPath: "/Users/sample")
        let running = URL(fileURLWithPath: "/Volumes/Download/OxSayDictation.app")
        let installed = InstalledApp.bundleURL(running: running, home: home, exists: { $0.path == "/Users/sample/Applications/OxSayDictation.app/Contents/Info.plist" },
                                                version: { _ in "0.1.28" })
        XCTAssertEqual(installed.path, "/Users/sample/Applications/OxSayDictation.app")
    }

    /// The installed copy is offered only when it is not older than the running one: a dev build run next to an
    /// old ~/Applications copy must not be "repaired" down to it. Reads versions through a fake, never ~/Applications.
    /// Mutation: InstalledApp.bundleURL, delete the `isNewer` check (always the installed copy) -> RED.
    func testAnOlderInstalledCopyIsNotPreferredToTheRunningOne() {
        let home = URL(fileURLWithPath: "/Users/sample")
        let running = URL(fileURLWithPath: "/Volumes/Build/OxSayDictation.app")
        let installedPath = "/Users/sample/Applications/OxSayDictation.app"
        func pick(installed: String?, running runningVersion: String?) -> String {
            InstalledApp.bundleURL(running: running, home: home, exists: { _ in true },
                                   version: { $0.path == installedPath ? installed : runningVersion }).path
        }
        XCTAssertEqual(pick(installed: "0.1.20", running: "0.1.28"), running.path, "older installed copy")
        XCTAssertEqual(pick(installed: "0.1.28", running: "0.1.28"), installedPath, "same version")
        XCTAssertEqual(pick(installed: "0.1.29", running: "0.1.28"), installedPath, "newer installed copy")
        XCTAssertEqual(pick(installed: "0.1.9", running: "0.1.10"), running.path, "numeric, not text, order")
        XCTAssertEqual(pick(installed: "0.1.20", running: nil), installedPath, "running version unknown: keep the old rule")
        XCTAssertEqual(pick(installed: nil, running: "0.1.28"), running.path, "installed version unreadable")
    }

    func testTheRunningCopyIsTheFallbackWhenNothingIsInstalled() {
        let running = URL(fileURLWithPath: "/Volumes/Download/OxSayDictation.app")
        let got = InstalledApp.bundleURL(running: running, home: URL(fileURLWithPath: "/Users/sample"), exists: { _ in false })
        XCTAssertEqual(got, running)
    }

    private func source(_ relative: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Mutation: AppDelegate.diskVersion reads `Bundle.main.bundleURL` again -> RED.
    func testDiskVersionReadsTheInstalledCopy() throws {
        let text = try source("Sources/OxSayDictation/AppDelegate.swift")
        guard let start = text.range(of: "nonisolated private static func diskVersion() -> String? {"),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else { return XCTFail("diskVersion not found") }
        let body = text[start.lowerBound..<end.upperBound]
        XCTAssertTrue(body.contains("InstalledApp.bundleURL(running: Bundle.main.bundleURL)"), "diskVersion does not read the installed copy")
    }

    /// Mutation: AppDelegate.relaunch passes `Bundle.main.bundleURL.path` again -> RED
    /// (a copy run from elsewhere would reopen itself, the old version).
    func testRelaunchOpensTheInstalledCopy() throws {
        let text = try source("Sources/OxSayDictation/AppDelegate.swift")
        guard let start = text.range(of: "private func relaunch() async -> Bool {"),
              let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else { return XCTFail("relaunch not found") }
        XCTAssertTrue(text[start.lowerBound..<end.upperBound].contains("bundlePath: InstalledApp.bundleURL(running: Bundle.main.bundleURL).path)"))
    }

    // #221.1
    func testTheInstallPillReturnsAfterANoticeOnlyWhileInstallingAndIdle() {
        XCTAssertTrue(InstallPill.restoreAfterNotice(installing: true, dictation: .idle))
        XCTAssertFalse(InstallPill.restoreAfterNotice(installing: false, dictation: .idle), "no install, no pill")
        XCTAssertFalse(InstallPill.restoreAfterNotice(installing: true, dictation: .recording), "a dictation owns the pill")
        XCTAssertFalse(InstallPill.restoreAfterNotice(installing: true, dictation: .transcribing))
    }

    /// Mutation: Overlay.showMessage's timeout closure drops the `onMessageExpired` consult -> RED;
    /// AppDelegate drops the `overlay.onMessageExpired =` wiring -> RED.
    func testTheNoticeTimeoutGivesTheInstallPillBack() throws {
        let overlay = try source("Sources/OxSayDictation/Overlay.swift")
        guard let start = overlay.range(of: "let timeout = DispatchWorkItem { [weak self] in"),
              let end = overlay.range(of: "messageTimeout = timeout", range: start.upperBound..<overlay.endIndex) else { return XCTFail("timeout closure not found") }
        let closure = overlay[start.lowerBound..<end.lowerBound]
        guard let ask = closure.range(of: "onMessageExpired?()"), let hide = closure.range(of: "self.hide()") else {
            return XCTFail("the message timeout does not ask the app before hiding")
        }
        XCTAssertLessThan(ask.lowerBound, hide.lowerBound)
        let app = try source("Sources/OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("overlay.onMessageExpired = "), "AppDelegate never wires onMessageExpired")
        XCTAssertTrue(app.contains("InstallPill.restoreAfterNotice(installing: updateInstalling, dictation: controller.state)"))
    }
}

// MARK: #325 — the update failure texts are in the user's language

final class UpdateFailureL10nTests: XCTestCase {
    /// One of every case, so a new `Failure` case cannot ship without a row here and in both string files.
    private static let every: [(UpdateInstaller.Failure, en: String, ru: String)] = [
        (.downloadFailed(status: 22),
         "Downloading the installer failed (curl exited with status 22).",
         "Не удалось скачать установщик (curl завершился с кодом 22)."),
        (.downloadTimedOut(seconds: 90),
         "Downloading the installer timed out after 90 s.",
         "Время на скачивание установщика вышло (90 с)."),
        (.downloadTimedOut(seconds: nil),
         "Downloading the installer timed out.",
         "Время на скачивание установщика вышло."),
        (.downloaderCouldNotStart("no such file"),
         "The download could not start: no such file.",
         "Скачивание не началось: no such file."),
        (.notAScript,
         "The downloaded installer was empty or not a script.",
         "Скачанный установщик пуст или не является скриптом."),
        (.installerFailed(status: 1),
         "The installer exited with status 1.",
         "Установщик завершился с кодом 1."),
        (.installerTimedOut(seconds: 1200),
         "The installer made no progress for 20 minutes and was stopped. Downloaded files are kept — run Update again to continue.",
         "Установка не продвигалась 20 мин и была остановлена. Скачанное сохранено — запустите обновление снова, чтобы продолжить."),
        (.couldNotStart("no such file"),
         "The installer could not start: no such file.",
         "Установщик не удалось запустить: no such file."),
        (.versionUnchanged(expected: "v0.1.21", found: "0.1.20"),
         "The version did not change: expected v0.1.21 after the install, found v0.1.20.",
         "Версия не изменилась: после установки ожидалась v0.1.21, а установлена v0.1.20."),
        (.versionUnchanged(expected: "v0.1.21", found: nil),
         "The version did not change: expected v0.1.21 after the install, found unknown.",
         "Версия не изменилась: после установки ожидалась v0.1.21, а установленную прочитать не удалось."),
        (.daemonNotOnVersion(expected: "v0.1.22", found: "v0.1.21"),
         "The ox-say service did not reach v0.1.22 after the install; /status reports v0.1.21.",
         "После установки служба ox-say не обновилась до v0.1.22: /status сообщает v0.1.21."),
        (.daemonNotOnVersion(expected: "v0.1.22", found: nil),
         "The ox-say service did not reach v0.1.22 after the install; /status reports nothing.",
         "После установки служба ox-say не обновилась до v0.1.22: /status не сообщил версию."),
    ]

    /// Mutation: UpdateInstall.swift Failure.message, `.notAScript` back to its English literal -> RED on the Russian row.
    func testEveryFailureReadsRightInBothLanguages() {
        for row in Self.every {
            XCTAssertEqual(row.0.message(text: ShippedStrings.localizer("en")), row.en)
            XCTAssertEqual(row.0.message(text: ShippedStrings.localizer("ru")), row.ru)
        }
    }

    /// Every case has a row above (the `switch` here has no default, so a new case does not compile until it is
    /// listed), and none of its texts is a missing key.
    func testEveryFailureCaseIsCoveredAndHasBothTexts() {
        var seen = Set<String>()
        for row in Self.every {
            switch row.0 {
            case .downloadFailed: seen.insert("downloadFailed")
            case .downloadTimedOut: seen.insert("downloadTimedOut")
            case .downloaderCouldNotStart: seen.insert("downloaderCouldNotStart")
            case .notAScript: seen.insert("notAScript")
            case .installerFailed: seen.insert("installerFailed")
            case .installerTimedOut: seen.insert("installerTimedOut")
            case .couldNotStart: seen.insert("couldNotStart")
            case .versionUnchanged: seen.insert("versionUnchanged")
            case .daemonNotOnVersion: seen.insert("daemonNotOnVersion")
            }
            for locale in ["en", "ru"] {
                XCTAssertFalse(row.0.message(text: ShippedStrings.localizer(locale)).contains("MISSING"), locale)
            }
        }
        XCTAssertEqual(seen.count, 9)
    }

    /// The alert around the message is localized too: its title and the pointer to the log.
    func testTheAlertTitleAndLogPointerAreInTheUsersLanguage() {
        let path = "/tmp/ox-say-update.log"
        XCTAssertEqual(UpdateInstaller.failureTitle(kind: .update, tag: "v0.1.22", text: enText), "Update to v0.1.22 failed")
        XCTAssertEqual(UpdateInstaller.failureTitle(kind: .update, tag: "v0.1.22", text: ruText), "Не удалось обновиться до v0.1.22")
        XCTAssertEqual(UpdateInstaller.failureTitle(kind: .studioVoice, tag: "v0.1.22", text: enText), "Installing the studio voice failed")
        XCTAssertEqual(UpdateInstaller.failureTitle(kind: .studioVoice, tag: "v0.1.22", text: ruText), "Не удалось установить студийный голос")
        XCTAssertEqual(UpdateInstaller.Failure.notAScript.alertText(logPath: path, text: enText),
                       "The downloaded installer was empty or not a script. Its output is in\n\(path)")
        XCTAssertEqual(UpdateInstaller.Failure.notAScript.alertText(logPath: path, text: ruText),
                       "Скачанный установщик пуст или не является скриптом. Вывод установщика записан в\n\(path)")
    }

    /// The app shows exactly this text, not a message it builds itself.
    func testTheAppShowsTheLocalizedAlertText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("failure.alertText(logPath: Self.updateLogURL.path)"))
        XCTAssertTrue(app.contains("UpdateInstaller.failureTitle(kind: kind, tag: tag)"))
        XCTAssertFalse(app.contains("failure.message"), "the alert must not build its own English text")
    }
}
