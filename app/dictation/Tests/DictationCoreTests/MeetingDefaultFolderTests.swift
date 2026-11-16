import Foundation
import XCTest
@testable import DictationCore

/// The default notes folder (#532): `~/Documents/ox-say Meetings` unless Documents syncs to iCloud, in which case a
/// first-time default is `~/Library/Application Support/ox-say Meetings`, so "nothing is uploaded" holds without the
/// user having to find a warning. A folder already in use, or one the user picked, is never moved. The filesystem and
/// the iCloud probe are injected: nothing here touches real iCloud state.
final class MeetingDefaultFolderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/i532d", isDirectory: true)
    private let documents = "/i532d/Documents/ox-say Meetings"
    private let local = "/i532d/Library/Application Support/ox-say Meetings"

    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "i532d-\(UUID().uuidString)")!
        return d
    }

    /// Documents is the only path the probe knows, and says "ubiquitous" (the sync is on): `nil` for the rest.
    private let syncedDocuments: ICloudSync.Probe = { url in url.path == "/i532d/Documents" ? true : (url.path == "/i532d" ? false : nil) }
    private let localDocuments: ICloudSync.Probe = { url in url.path == "/i532d/Documents" ? false : (url.path == "/i532d" ? false : nil) }
    private let nothingExists: (URL) -> Bool = { _ in false }

    /// Mutation: MeetingSettings.folder, `ICloudSync.syncs(...) ? local : documents` -> `documents` -> RED.
    func testASyncedDocumentsGivesTheLocalDefaultToANewUser() {
        let folder = MeetingSettings.folder(defaults(), home: home, probe: syncedDocuments, exists: nothingExists)
        XCTAssertEqual(folder.path, local)
        XCTAssertFalse(ICloudSync.syncs(folder, home: home, probe: syncedDocuments),
                       "the folder the default picks is itself not synced")
    }

    /// Mutation: MeetingSettings.folder, the ternary's `: documents` -> `: local` -> RED.
    func testALocalDocumentsKeepsTheDocumentsDefault() {
        XCTAssertEqual(MeetingSettings.folder(defaults(), home: home, probe: localDocuments, exists: nothingExists).path, documents)
    }

    /// A person with notes already there keeps them there, and the Settings warning speaks for it.
    /// Mutation: MeetingSettings.folder, delete the `if exists(documents)` line -> RED.
    func testAnExistingDocumentsFolderIsNeverMoved() {
        let folder = MeetingSettings.folder(defaults(), home: home, probe: syncedDocuments,
                                            exists: { $0.path == self.documents })
        XCTAssertEqual(folder.path, documents)
    }

    /// Once the local default is in use it stays, if the sync setting is flipped later.
    /// Mutation: MeetingSettings.folder, delete the `if exists(local)` line -> RED.
    func testTheLocalDefaultStaysOnceItExists() {
        let folder = MeetingSettings.folder(defaults(), home: home, probe: localDocuments,
                                            exists: { $0.path == self.local })
        XCTAssertEqual(folder.path, local)
    }

    /// An explicit pick wins over both, synced or not.
    /// Mutation: MeetingSettings.folder, move the stored-pick `guard` below the default logic -> RED.
    func testAPickedFolderWinsEvenWhenItSyncs() {
        let d = defaults()
        MeetingSettings.setFolder(URL(fileURLWithPath: "/i532d/Documents/mine", isDirectory: true), d)
        XCTAssertEqual(MeetingSettings.folder(d, home: home, probe: syncedDocuments, exists: nothingExists).path, "/i532d/Documents/mine")
    }

    /// The page and the export read the same folder: the model's path and warning follow the default's choice.
    /// Mutation: MeetingSettingsModel.load, `probe: probe` removed from the `MeetingSettings.folder` call -> RED
    /// (the real probe answers for a path that does not exist: not synced, so the default stays in Documents).
    func testTheSettingsModelShowsTheLocalDefaultWithoutAWarning() {
        let v = MeetingSettingsModel.load(defaults: defaults(), daemonRetention: nil, notesWriter: .ready,
                                          fullName: "x", home: home, probe: syncedDocuments)
        XCTAssertEqual(v.folderPath, local)
        XCTAssertFalse(v.folderSyncsICloud)
    }

    /// The property itself (#532), through the export: a first-ever export on a Mac whose Documents syncs lands in the
    /// local folder, not under Documents. The home is a real temporary directory, so the file really is written.
    /// Mutation: MeetingExporter.export, `MeetingSettings.folder(defaults, home: home, probe: probe)` ->
    /// `MeetingSettings.folder(defaults, home: home, probe: { _ in false })` -> RED.
    func testAFirstExportOnASyncedDocumentsMacLandsOutsideDocuments() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("i532-export-\(UUID().uuidString)", isDirectory: true)
        let documents = tmp.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        // Like the real probe: Documents answers true, a path that does not exist answers nil.
        let synced: ICloudSync.Probe = { url in
            url.standardizedFileURL.path == documents.standardizedFileURL.path ? true : (fm.fileExists(atPath: url.path) ? false : nil)
        }
        let info = MeetingInfo(id: "m1", title: "Plan", started: Date(timeIntervalSince1970: 1_700_000_000), status: .done,
                               notesMD: "notes", transcriptMD: "text")
        guard case .written(let dir) = MeetingExporter(defaults: defaults(), home: tmp, probe: synced).export(info) else {
            return XCTFail("the export did not write a copy")
        }
        XCTAssertTrue(dir.standardizedFileURL.path.hasPrefix(tmp.appendingPathComponent("Library/Application Support/ox-say Meetings").standardizedFileURL.path),
                      "the copy went to \(dir.path)")
        XCTAssertFalse(fm.fileExists(atPath: documents.appendingPathComponent("ox-say Meetings").path), "nothing was written under Documents")
    }
}
