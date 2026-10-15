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
                                               daemon: "v0.1.23", kickstarts: 0),
                       .relaunchSelf)
    }

    func testMatchingVersionsDoNothing() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "v0.1.22", kickstarts: 0), VersionHandshake.Action.none)
    }

    func testTheVPrefixDoesNotCountAsAMismatch() {
        // The daemon reports "v0.1.22"; the bundle's plist writes "0.1.22".
        XCTAssertEqual(VersionHandshake.decide(app: "v0.1.22", disk: "0.1.22",
                                               daemon: "v0.1.22", kickstarts: 0), VersionHandshake.Action.none)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "v0.1.22",
                                               daemon: "0.1.22", kickstarts: 0), VersionHandshake.Action.none)
    }

    /// A newer running process than the bundle on disk is a downgrade in
    /// flight; it must never relaunch into the older copy.
    func testANewerRunningAppDoesNothing() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.24", disk: "0.1.23",
                                               daemon: "v0.1.23", kickstarts: 0), VersionHandshake.Action.none)
    }

    /// Mutation: drop `kickstarts < maxKickstarts` so a stale daemon is
    /// kickstarted forever -> the second assert goes RED.
    func testAStaleDaemonIsKickstartedOnlyBelowTheLimit() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23",
                                               daemon: "v0.1.22", kickstarts: 0),
                       .kickstartDaemon)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.22",
                                               kickstarts: VersionHandshake.maxKickstarts - 1),
                       .kickstartDaemon)
    }

    /// Mutation: offerRepair's `target` built from the daemon's version
    /// instead of the disk version -> RED (a repair to the wrong tag).
    func testAStillStaleDaemonOffersRepairToTheDiskVersion() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.23", disk: "0.1.23", daemon: "v0.1.21",
                                               kickstarts: VersionHandshake.maxKickstarts),
                       .offerRepair(target: "0.1.23"))
    }

    /// Mutation: release() answering non-nil for "0.0.0" or for garbage ->
    /// all of these go RED.
    func testDevAndUnparseableVersionsNeverAct() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.0.0", disk: "0.1.23",
                                               daemon: "v0.1.23", kickstarts: 0), VersionHandshake.Action.none,
                       "a dev app must not relaunch, kickstart or repair")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.0.0",
                                               daemon: "v0.1.22", kickstarts: 0), VersionHandshake.Action.none,
                       "a dev bundle on disk is never an update to relaunch into")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "dev", kickstarts: 0), VersionHandshake.Action.none,
                       "a dev daemon reports \"dev\", not a version to chase")
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: "latest", kickstarts: 0), VersionHandshake.Action.none)
    }

    /// A daemon that did not answer is the existing "not answering" state:
    /// never a kickstart, never a repair row.
    func testAnUnreachableDaemonIsNotAMismatch() {
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: nil, kickstarts: 0), VersionHandshake.Action.none)
        XCTAssertEqual(VersionHandshake.decide(app: "0.1.22", disk: "0.1.22",
                                               daemon: nil, kickstarts: 5), VersionHandshake.Action.none)
    }

    /// The agreement check that ends an episode: only a parseable answer equal
    /// to the disk version resets the kickstart count.
    func testOnlyAnAgreeingDaemonResetsAnEpisode() {
        XCTAssertTrue(VersionHandshake.agrees(daemon: "v0.1.22", disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: "v0.1.21", disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: nil, disk: "0.1.22"))
        XCTAssertFalse(VersionHandshake.agrees(daemon: "dev", disk: "0.1.22"))
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
