import XCTest
@testable import DictationCore

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
        XCTAssertEqual(f?.message, "The version did not change: expected v0.1.21 after the install, found v0.1.20.")
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
        XCTAssertEqual(failure?.message,
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
        XCTAssertEqual(UpdateInstaller.Failure.downloadFailed(status: 22).message,
                       "Downloading the installer failed (curl exited with status 22).")
        XCTAssertEqual(UpdateInstaller.Failure.installerFailed(status: 1).message, "The installer exited with status 1.")
        XCTAssertEqual(UpdateInstaller.Failure.couldNotStart("no such file").message, "The installer could not start: no such file.")
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
        XCTAssertTrue(failure?.message.contains("timed out") ?? false, failure?.message ?? "nil")
    }

    func testACurlThatCannotStartHasItsOwnText() async {
        let failure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                downloadArgv: { _, _ in ["/nonexistent/curl"] },
                                                installedVersion: { nil }, daemonVersion: { nil })
        guard case .downloaderCouldNotStart? = failure else { return XCTFail("got \(String(describing: failure))") }
        XCTAssertTrue(failure?.message.hasPrefix("The download could not start:") ?? false, failure?.message ?? "nil")
    }

    func testTheScriptHeadReadHasANamedLength() {
        XCTAssertEqual(UpdateInstaller.scriptHeadLength, 2, "`#!` is two bytes")
    }

    // The installed copy, not the running one.
    func testTheInstalledCopyIsReadWhenItExists() {
        let home = URL(fileURLWithPath: "/Users/sample")
        let running = URL(fileURLWithPath: "/Volumes/Download/OxSayDictation.app")
        let installed = InstalledApp.bundleURL(running: running, home: home, exists: { $0.path == "/Users/sample/Applications/OxSayDictation.app/Contents/Info.plist" })
        XCTAssertEqual(installed.path, "/Users/sample/Applications/OxSayDictation.app")
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
