import Foundation
import XCTest
@testable import DictationCore

/// `ICloudSync.syncs` — "would macOS upload what lands in this folder" (#532): a path inside an
/// iCloud ubiquity container, or the item (or the nearest existing ancestor, since the notes
/// folder may not be created yet) marked `isUbiquitousItem`, which is how "Desktop & Documents"
/// sync marks ~/Documents and ~/Desktop. The probe is injected, so nothing here touches real
/// iCloud state.
final class ICloudSyncTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/i532home", isDirectory: true)

    /// A probe from a table: `isUbiquitousItem` per path; a path the table lacks does not exist.
    private func probe(_ answers: [String: Bool]) -> ICloudSync.Probe {
        { url in answers[url.path] }
    }

    /// `~/Library/Mobile Documents` holds every ubiquity container: the path alone puts a folder
    /// in iCloud, whatever the item probe says.
    /// Mutation: ICloudSync.syncs, delete the `underMobileDocuments` checks -> RED.
    func testAFolderInsideMobileDocumentsSyncs() {
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/notes", isDirectory: true)
        XCTAssertTrue(ICloudSync.syncs(drive, home: home, probe: { _ in false }), "the iCloud Drive container")
        let app = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~example~app/notes", isDirectory: true)
        XCTAssertTrue(ICloudSync.syncs(app, home: home, probe: { _ in false }), "an app's own ubiquity container")
        XCTAssertTrue(ICloudSync.syncs(home.appendingPathComponent("Library/Mobile Documents", isDirectory: true),
                                     home: home, probe: { _ in false }), "the containers root itself")
    }

    /// Synced ~/Documents stays at its home path — nothing in it says Mobile Documents — but macOS
    /// marks it ubiquitous.
    /// Mutation: ICloudSync.syncs, `if let answer { return answer }` -> `return false` -> RED.
    func testAUbiquitousFolderSyncs() {
        let folder = home.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
        XCTAssertTrue(ICloudSync.syncs(folder, home: home, probe: probe([folder.path: true])))
    }

    /// The notes folder may not exist yet: the nearest ancestor that does gives the answer, and a
    /// local ancestor means local.
    /// Mutation: ICloudSync.syncs, probe `folder` only and return its answer (no walk to the
    /// nearest existing ancestor) -> RED (a not-yet-created subfolder of a synced folder reads
    /// "not synced").
    func testAMissingFolderTakesTheNearestExistingAncestorsAnswer() {
        let folder = URL(fileURLWithPath: "/i532/parent/notes", isDirectory: true)
        XCTAssertTrue(ICloudSync.syncs(folder, home: home, probe: probe(["/i532/parent": true])),
                      "the created parent is synced, the new folder inherits it")
        XCTAssertFalse(ICloudSync.syncs(folder, home: home, probe: probe(["/i532/parent": false])),
                       "a local parent keeps it local")
    }

    func testALocalFolderDoesNotSync() {
        let folder = home.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
        XCTAssertFalse(ICloudSync.syncs(folder, home: home,
                                        probe: probe([home.appendingPathComponent("Documents").path: false])))
    }

    /// Every ancestor missing (the whole path is new) reads as not synced, not as a crash or a
    /// wrong warning.
    func testNothingExistingMeansNotSynced() {
        let folder = home.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
        XCTAssertFalse(ICloudSync.syncs(folder, home: home, probe: { _ in nil }))
    }

    /// The walk must end at the root. `URL.deletingLastPathComponent` on `file:///` gives `file:///../`,
    /// then `file:///../../`, and so on: a URL built by `appendingPathComponent` never equals its own
    /// parent, so a loop that stops on `parent == candidate` spins forever when no ancestor answers.
    /// The probe counts its calls and answers "exists, local" after 64, so the mutant fails instead of hanging.
    /// Mutation: ICloudSync.syncs, the counted `for` walk -> `while true` ending on
    /// `parent == candidate` -> RED (calls pile up past the root).
    func testTheWalkEndsAtTheRootWhenNothingAnswers() {
        var calls = 0
        let probe: ICloudSync.Probe = { _ in calls += 1; return calls > 64 ? false : nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("i532-a/b", isDirectory: true)
        XCTAssertFalse(ICloudSync.syncs(folder, home: home, probe: probe))
        XCTAssertLessThanOrEqual(calls, 32, "the walk climbed past the root")
    }

    /// A probe that throws means "unknown", and unknown is not a sync answer — and no crash.
    /// Mutation: ICloudSync.syncs, `catch { return false }` -> `catch { fatalError() }` -> crash here.
    func testAThrowingProbeMeansNotSynced() {
        struct Unknown: Error {}
        let folder = home.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
        XCTAssertFalse(ICloudSync.syncs(folder, home: home, probe: { _ in throw Unknown() }))
    }

    /// A symlink the user picked lands inside a container even though the literal path shows no
    /// "Mobile Documents".
    /// Mutation: ICloudSync.syncs, drop the `folder.resolvingSymlinksInPath()` check -> RED.
    func testASymlinkIntoAContainerSyncs() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("i532-\(UUID().uuidString)", isDirectory: true)
        let container = tmp.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("Documents"), withDestinationURL: container)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The probe mimics the real one — nil for a path that does not exist — so the walk
        // climbs past the missing tail to `Documents`, the symlink, and its resolved path lands
        // inside the container.
        let folder = tmp.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
        XCTAssertTrue(ICloudSync.syncs(folder, home: tmp, probe: probe([:])))
    }

    /// The flag the Settings page reads follows the stored folder across loads: picking a folder
    /// off iCloud drops the warning.
    /// Mutation: MeetingSettingsModel.load, hoist `ICloudSync.syncs` to a cached or fixed value ->
    /// RED (a folder moved off iCloud keeps the old answer, or the flag is never set).
    func testTheModelFlagFollowsTheFolderAcrossLoads() {
        let d = UserDefaults(suiteName: "i532-\(UUID().uuidString)")!
        let answers = ["/i532/icloud": true, "/i532/local": false]
        let load = {
            MeetingSettingsModel.load(defaults: d, daemonRetention: nil, notesWriter: .ready,
                                      fullName: "x", home: self.home, probe: { url in answers[url.path] })
        }
        MeetingSettings.setFolder(URL(fileURLWithPath: "/i532/icloud", isDirectory: true), d)
        XCTAssertTrue(load().folderSyncsICloud)
        MeetingSettings.setFolder(URL(fileURLWithPath: "/i532/local", isDirectory: true), d)
        XCTAssertFalse(load().folderSyncsICloud)
    }

    /// The picker's one step (#532): the picked folder is stored and the flag is the new folder's
    /// own answer, so the page cannot keep the previous folder's warning.
    /// Mutation: MeetingSettingsModel.folderPicked, read the values before `MeetingSettings.setFolder`
    /// (or pin `folderSyncsICloud` instead of recomputing) -> RED.
    func testTheFolderPickStoresAndRecomputesTheFlag() {
        let d = UserDefaults(suiteName: "i532-\(UUID().uuidString)")!
        let answers = ["/i532/icloud": true, "/i532/local": false, "/i532/icloud-too": true]
        func pick(_ path: String) -> MeetingSettingsValues {
            MeetingSettingsModel.folderPicked(URL(fileURLWithPath: path, isDirectory: true), defaults: d,
                                              daemonRetention: nil, notesWriter: .ready, fullName: "x",
                                              home: home, probe: { url in answers[url.path] })
        }
        var v = pick("/i532/icloud")
        XCTAssertEqual(v.folderPath, "/i532/icloud", "the pick is stored")
        XCTAssertTrue(v.folderSyncsICloud)
        v = pick("/i532/local")
        XCTAssertEqual(v.folderPath, "/i532/local")
        XCTAssertFalse(v.folderSyncsICloud, "moved off iCloud: the old warning is gone")
        v = pick("/i532/icloud-too")
        XCTAssertTrue(v.folderSyncsICloud, "and back on again")
        XCTAssertEqual(MeetingSettings.folder(d, home: home).path, "/i532/icloud-too")
    }

    /// The honest variant names iCloud in both locales; the key-set tests pin its presence.
    func testTheHonestVariantNamesICloudInBothLocales() {
        for locale in ["en", "ru"] {
            XCTAssertTrue((ShippedStrings.table(locale)["privacy.line.icloud"] ?? "").contains("iCloud"), locale)
        }
    }
}
