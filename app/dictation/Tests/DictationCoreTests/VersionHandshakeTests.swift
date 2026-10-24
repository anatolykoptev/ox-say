import XCTest
@testable import DictationCore

/// The version handshake's decision table — every row, including the ones a
/// user must never see act (a dev build, an unreachable daemon).
final class VersionHandshakeTests: XCTestCase {

    // MARK: the table

    /// Mutation: decide's `running.lexicographicallyPrecedes(bundle)` inverted
    /// (or dropped) -> RED.
    func testAnOlderRunningAppRelaunchesIntoTheBundleOnDisk() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.23",
                                               daemon: "v0.1.23", kickstarts: 0, serviceIdle: true, appIdle: true),
                       .relaunchSelf)
    }

    func testMatchingVersionsDoNothing() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "v0.1.22", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
    }

    func testTheVPrefixDoesNotCountAsAMismatch() {
        // The daemon reports "v0.1.22"; the bundle's plist writes "0.1.22".
        XCTAssertEqual(VersionHandshake.decide(app: "v0.1.22", disk: "0.1.22",
                                               daemon: "v0.1.22", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "v0.1.22",
                                               daemon: "0.1.22", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
    }

    /// A newer running process than the bundle on disk is a downgrade in
    /// flight; it must never relaunch into the older copy.
    func testANewerRunningAppDoesNothing() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.24", disk: "0.1.23",
                                               daemon: "v0.1.23", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
    }

    /// Mutation: drop `kickstarts < maxKickstarts` so a stale daemon is
    /// kickstarted forever -> the second assert goes RED.
    func testAStaleDaemonIsKickstartedOnlyBelowTheLimit() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23",
                                               daemon: "v0.1.22", kickstarts: 0, serviceIdle: true, appIdle: true),
                       .kickstartDaemon)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.22",
                                               kickstarts: VersionHandshake.maxKickstarts - 1,
                                               serviceIdle: true, appIdle: true),
                       .kickstartDaemon)
    }

    /// Mutation: offerRepair's `target` built from the daemon's version
    /// instead of the disk version -> RED (a repair to the wrong tag).
    func testAStillStaleDaemonOffersRepairToTheDiskVersion() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.21",
                                               kickstarts: VersionHandshake.maxKickstarts,
                                               serviceIdle: true, appIdle: true),
                       .offerRepair(target: "0.1.23"))
    }

    /// Mutation: release() answering non-nil for "0.0.0" or for garbage ->
    /// all of these go RED.
    func testDevAndUnparseableVersionsNeverAct() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.0.0", disk: "0.1.23",
                                               daemon: "v0.1.23", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none,
                       "a dev app must not relaunch, kickstart or repair")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.0.0",
                                               daemon: "v0.1.22", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none,
                       "a dev bundle on disk is never an update to relaunch into")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "dev", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none,
                       "a dev daemon reports \"dev\", not a version to chase")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "latest", kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
    }

    /// A daemon that did not answer is the existing "not answering" state:
    /// never a kickstart, never a repair row.
    func testAnUnreachableDaemonIsNotAMismatch() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: nil, kickstarts: 0, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: nil, kickstarts: 5, serviceIdle: true, appIdle: true), VersionHandshake.Action.none)
    }

    /// The agreement check that ends an episode: only a parseable answer equal
    /// to the disk version resets the kickstart count.
    func testOnlyAnAgreeingDaemonResetsAnEpisode() {
        XCTAssertTrue(VersionHandshake.agrees(daemon: "v0.1.22", disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: "v0.1.21", disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: nil, disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: "dev", disk: "0.1.22"))
    }

    // MARK: work in flight defers the destructive actions

    private func row(app: String = "0.1.23", daemon: String?, kickstarts: Int = 0,
                     serviceIdle: Bool, appIdle: Bool) -> VersionHandshake.Action {
        VersionHandshake.decide(app: app, disk: "0.1.23", daemon: daemon, kickstarts: kickstarts,
                                serviceIdle: serviceIdle, appIdle: appIdle)
    }

    /// The daemon sees CLI, MCP and HTTP load the app cannot; its report alone
    /// must hold a kickstart and a relaunch back.
    /// Mutation: VersionHandshake.swift decide, the `serviceIdle &&` dropped from
    /// the kickstart branch's condition -> RED (first assert); dropped from the
    /// relaunch branch's -> RED (second).
    func testABusyDaemonDefersTheKickstartAndTheRelaunch() {
        XCTAssertEqual(row(daemon: "v0.1.22", serviceIdle: false, appIdle: true), .deferUntilIdle)
        XCTAssertEqual(row(app: "0.1.22", daemon: "v0.1.23", serviceIdle: false, appIdle: true), .deferUntilIdle)
        XCTAssertEqual(row(daemon: "v0.1.22", serviceIdle: true, appIdle: true), .kickstartDaemon)
        XCTAssertEqual(row(app: "0.1.22", daemon: "v0.1.23", serviceIdle: true, appIdle: true), .relaunchSelf)
    }

    /// Mutation: the `appIdle` half of either condition dropped -> RED.
    func testABusyAppDefersTheKickstartAndTheRelaunch() {
        XCTAssertEqual(row(daemon: "v0.1.22", serviceIdle: true, appIdle: false), .deferUntilIdle)
        XCTAssertEqual(row(app: "0.1.22", daemon: "v0.1.23", serviceIdle: true, appIdle: false), .deferUntilIdle)
        XCTAssertEqual(row(daemon: "v0.1.22", serviceIdle: false, appIdle: false), .deferUntilIdle)
    }

    /// Nothing to act on is nothing to defer, and the user-initiated Repair
    /// row does not wait for idle.
    func testBusyChangesNothingWhereThereIsNothingToDo() {
        XCTAssertEqual(row(daemon: "v0.1.23", serviceIdle: false, appIdle: false), VersionHandshake.Action.none)
        XCTAssertEqual(row(daemon: nil, serviceIdle: false, appIdle: false), VersionHandshake.Action.none)
        XCTAssertEqual(row(daemon: "v0.1.21", kickstarts: VersionHandshake.maxKickstarts,
                           serviceIdle: false, appIdle: false), .offerRepair(target: "0.1.23"))
    }

    /// A deferral is not an attempt: any number of busy passes leave the full
    /// kickstart budget for the idle one.
    /// Mutation: AppDelegate-facing Episode.decide, the `case .relaunchSelf,
    /// .deferUntilIdle:` arm also doing `kickstarts += 1` (or `.deferUntilIdle`
    /// moved under `.kickstartDaemon`) -> RED.
    func testADeferralConsumesNoKickstart() {
        var episode = VersionHandshake.Episode()
        for _ in 0..<10 {
            XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.22",
                                          serviceIdle: false, appIdle: true), .deferUntilIdle)
        }
        XCTAssertEqual(episode.kickstarts, 0)
        for fired in 1...VersionHandshake.maxKickstarts {
            XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.22",
                                          serviceIdle: true, appIdle: true), .kickstartDaemon)
            XCTAssertEqual(episode.kickstarts, fired)
        }
        XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.22",
                                      serviceIdle: true, appIdle: true), .offerRepair(target: "0.1.23"))
    }

    /// The pass as the app calls it: /status's own `idle` and the app's work
    /// are what reach the table.
    /// Mutation: Episode.decide(status:work:), `status?.idle ?? true` -> `true`
    /// (or `work.idle` -> `true`) -> RED.
    func testThePassTakesTheDaemonsIdleFlagAndTheAppsWork() {
        let busyDaemon = DaemonStatus(version: "v0.1.22", studioAvailable: false, idle: false)
        let quietDaemon = DaemonStatus(version: "v0.1.22", studioAvailable: false, idle: true)
        let quiet = VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false, recordingMeeting: false)
        let dictating = VersionHandshake.AppWork(dictating: true, speaking: false, designing: false, followingVoiceover: false, recordingMeeting: false)
        var episode = VersionHandshake.Episode()
        XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", status: busyDaemon, work: quiet), .deferUntilIdle)
        XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", status: quietDaemon, work: dictating), .deferUntilIdle)
        XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", status: nil, work: dictating), VersionHandshake.Action.none,
                       "an unreachable daemon is never a mismatch, busy app or not")
        XCTAssertEqual(episode.decide(app: "0.1.23", disk: "0.1.23", status: quietDaemon, work: quiet), .kickstartDaemon)
    }

    func testTheAppIsIdleOnlyWhenEveryLaneIsEmpty() {
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false,
                                               followingVoiceover: false, recordingMeeting: false).idle)
        // Mutation: AppWork.idle, any one operand dropped -> its row RED.
        XCTAssertFalse(VersionHandshake.AppWork(dictating: true, speaking: false, designing: false,
                                                followingVoiceover: false, recordingMeeting: false).idle)
        XCTAssertFalse(VersionHandshake.AppWork(dictating: false, speaking: true, designing: false,
                                                followingVoiceover: false, recordingMeeting: false).idle)
        XCTAssertFalse(VersionHandshake.AppWork(dictating: false, speaking: false, designing: true,
                                                followingVoiceover: false, recordingMeeting: false).idle)
        XCTAssertFalse(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false,
                                                followingVoiceover: true, recordingMeeting: false).idle)
    }

    // MARK: the repair target follows the table

    private func offered() -> VersionHandshake.Episode {
        var episode = VersionHandshake.Episode()
        for _ in 0...VersionHandshake.maxKickstarts {
            _ = episode.decide(app: "0.1.21", disk: "0.1.21", daemon: "v0.1.20", serviceIdle: true, appIdle: true)
        }
        return episode
    }

    func testAnEscalatedEpisodeOffersRepairToTheDiskVersion() {
        XCTAssertEqual(offered().repairTarget, "0.1.21")
    }

    /// The bundle on disk moved on mid-episode: Repair must not reinstall the
    /// version that is no longer on disk. The daemon is unreachable on this pass
    /// so no table arm retracts the row — only the disk-change reset does.
    /// Mutation: Episode.decide, the `repairTarget = nil` line in the disk-change
    /// branch deleted -> RED.
    func testRepairIsRetractedWhenTheDiskVersionChanges() {
        var episode = offered()
        _ = episode.decide(app: "0.1.22", disk: "0.1.22", daemon: nil, serviceIdle: true, appIdle: true)
        XCTAssertNil(episode.repairTarget)
        XCTAssertEqual(episode.kickstarts, 0)
    }

    /// Mutation: Episode.decide, `if daemon != nil { repairTarget = nil }` deleted
    /// -> the dev and agreeing rows RED.
    func testRepairIsRetractedWhenTheDaemonBecomesDevUnparseableOrAgrees() {
        for answer in ["dev", "latest", "v0.1.21"] {
            var episode = offered()
            XCTAssertNotNil(episode.repairTarget)
            let action = episode.decide(app: "0.1.21", disk: "0.1.21", daemon: answer, serviceIdle: true, appIdle: true)
            XCTAssertEqual(action, VersionHandshake.Action.none, answer)
            XCTAssertNil(episode.repairTarget, "a \(answer) daemon: no Repair row")
        }
    }

    /// An unreachable daemon confirms nothing either way: the row stays.
    func testAnUnreachableDaemonLeavesTheRepairRow() {
        var episode = offered()
        _ = episode.decide(app: "0.1.21", disk: "0.1.21", daemon: nil, serviceIdle: true, appIdle: true)
        XCTAssertEqual(episode.repairTarget, "0.1.21")
    }

    // MARK: the kickstart runs off the caller

    func testKickstartReportsAnExitStatus() async {
        let ok = await VersionHandshake.runKickstart(argv: ["/usr/bin/true"], timeout: 5)
        XCTAssertEqual(ok, .exited(0))
        let failed = await VersionHandshake.runKickstart(argv: ["/usr/bin/false"], timeout: 5)
        XCTAssertEqual(failed, .exited(1))
    }

    /// A process that cannot launch is reported and never waited on.
    func testAKickstartThatCannotLaunchIsReportedNotAwaited() async {
        let outcome = await VersionHandshake.runKickstart(argv: ["/nonexistent/launchctl"], timeout: 5)
        XCTAssertEqual(outcome, .couldNotStart)
    }

    /// A wedged launchctl is ended at the timeout instead of hanging the pass.
    /// Mutation: UpdateInstall.swift runProcess, the `guard let timeout` timer
    /// block deleted -> this test waits out the 30 s sleep and fails on the time bound.
    func testAWedgedKickstartIsEndedAtTheTimeout() async {
        let started = Date()
        let outcome = await VersionHandshake.runKickstart(argv: ["/bin/sleep", "30"], timeout: 0.3)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "returned at the timeout, not at the process's end")
    }

    // MARK: the kickstart argv and the label

    /// Mutation: kickstartCommand without "-k", or the label spelled
    /// differently -> RED.
    func testKickstartArgvTargetsTheAgentsLabel() {
        XCTAssertEqual(VersionHandshake.kickstartCommand(uid: 501),
                       ["/bin/launchctl", "kickstart", "-k",
                        "gui/501/io.github.anatolykoptev.ox-say"])
    }

    /// The label constant exists so it is not typed twice: the template's
    /// filename is <label>.plist.in and its Label key carries the label.
    func testTheLabelMatchesTheLaunchAgentTemplate() throws {
        // #filePath is <repo>/app/dictation/Tests/DictationCoreTests/<this file>.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let template = root.appendingPathComponent("launchd/\(DaemonAddress.agentLabel).plist.in")
        let data = try Data(contentsOf: template)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["Label"] as? String, DaemonAddress.agentLabel,
                       "the template's Label key, its filename and agentLabel are one value")
        XCTAssertEqual(DaemonAddress.agentPlist.lastPathComponent,
                       "\(DaemonAddress.agentLabel).plist",
                       "the plist path the app reads is the label the installer writes")
    }
}
