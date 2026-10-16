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
        XCTAssertTrue(command.environment.isEmpty)
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
        var args: String { (try? String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)) ?? "<not run>" }

        init(script: String? = nil) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-install-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("get.sh")
            let body = script ?? "#!/bin/sh\nprintf '%s' \"$OX_SAY_WITH_VOXCPM2\" > '\(dir.path)/env'\nprintf '%s' \"$*\" > '\(dir.path)/args'\n"
            try body.write(to: file, atomically: true, encoding: .utf8)
            source = "file://" + file.path
        }

        func cleanUp() {
            for name in ["get.sh", "env", "args"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
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
        let studio = try Rig()
        defer { studio.cleanUp() }
        let failure = await UpdateInstaller.run(kind: .studioVoice, tag: "v0.1.21", log: nil,
                                                scriptSource: studio.source,
                                                installedVersion: { "0.1.21" }, daemonVersion: { "v0.1.21" })
        XCTAssertNil(failure)
        XCTAssertEqual(studio.env, "1", "the installer process must get OX_SAY_WITH_VOXCPM2=1")
        XCTAssertEqual(studio.args, "--version v0.1.21")

        let update = try Rig()
        defer { update.cleanUp() }
        let updateFailure = await UpdateInstaller.run(kind: .update, tag: "v0.1.22", log: nil,
                                                      scriptSource: update.source,
                                                      installedVersion: { "0.1.22" }, daemonVersion: { "v0.1.22" })
        XCTAssertNil(updateFailure)
        XCTAssertEqual(update.env, "", "a plain update must not download the studio model")
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
