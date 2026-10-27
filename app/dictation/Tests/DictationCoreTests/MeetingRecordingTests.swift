import Foundation
import XCTest
@testable import DictationCore

/// Task 17: the decisions behind the recorder and the controller, which the AppKit code only carries out.
final class SystemAudioGuardTests: XCTestCase {
    private func assess(callbacks: Int = 100, peak: Float = 0, elapsed: TimeInterval = 10, playingFor: TimeInterval = 10,
                        heardLoud: Bool = false) -> SystemAudioGuard.Verdict {
        SystemAudioGuard.assess(.init(callbacks: callbacks, peak: peak, elapsed: elapsed, playingFor: playingFor, heardLoud: heardLoud))
    }

    /// P0a, 2026-10-26: the toggle shows ON, the tap's callbacks fire and every sample is zero until the user switches
    /// it off and on. Callbacks + digital silence + a process playing = say so.
    /// Mutation: SystemAudioGuard.assess, delete the `peak == 0, playingFor >= …` branch -> RED.
    func testCallbacksWithOnlyZerosWhileSomethingPlaysIsTheSilentTap() {
        XCTAssertEqual(assess(), .silentTap)
    }

    func testNothingPlayingIsNotASilentTap() {
        XCTAssertEqual(assess(playingFor: 0), .waiting)
        XCTAssertEqual(assess(playingFor: SystemAudioGuard.playingBeforeVerdict - 0.5), .waiting)
    }

    func testAnyRealSampleMeansTheTapWorks() {
        XCTAssertEqual(assess(peak: 0.0005), .waiting, "quiet is not zero")
        XCTAssertEqual(assess(peak: 0.2, heardLoud: true), .fine)
    }

    func testTooEarlyIsNeverAVerdict() {
        XCTAssertEqual(assess(elapsed: SystemAudioGuard.settle - 0.1), .waiting)
        XCTAssertEqual(assess(callbacks: 0, elapsed: SystemAudioGuard.settle - 0.1), .waiting)
    }

    /// No callback at all after the settle time: the tap never delivered anything.
    /// Mutation: SystemAudioGuard.assess, delete the `callbacks == 0` branch -> RED.
    func testNoCallbacksIsSaidToo() {
        XCTAssertEqual(assess(callbacks: 0, playingFor: 0), .noCallbacks)
    }

    /// The old 20-second rule stays: audible nothing from the other side for 20 s.
    /// Mutation: SystemAudioGuard.assess, delete the `elapsed >= quietAfter` branch -> RED.
    func testAQuietOtherSideIsSaidAfterTwentySeconds() {
        XCTAssertEqual(assess(peak: 0.0002, elapsed: 19, playingFor: 0), .waiting)
        XCTAssertEqual(assess(peak: 0.0002, elapsed: 21, playingFor: 0), .otherSideQuiet)
    }

    func testThePaneAddressIsTheScreenAndSystemAudioPane() {
        XCTAssertEqual(SystemAudioGuard.settingsURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// One sentence in each language that names the whole path to the toggle.
    func testTheSilentTapSentenceNamesTheSettingsPath() {
        XCTAssertTrue(L10nKey.noticeMeetingTapSilent.rawValue.hasPrefix("notice.meeting."))
    }
}

final class MeetingLimitsTests: XCTestCase {
    private func goDiarSeconds() throws -> Int {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("internal/daemon/diarize.go"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"diarMaxSeconds\s*=\s*(\d+)\s*\*\s*(\d+)"#)
        let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "diarMaxSeconds not found")
        let a = Int(text[Range(m.range(at: 1), in: text)!])!
        let b = Int(text[Range(m.range(at: 2), in: text)!])!
        return a * b
    }

    /// A recording longer than the daemon's voice-separation cap loses its speakers (too_long). The app stops under it,
    /// by more than the stop's own lag (one tick of the 0.25 s badge timer and the finish call).
    /// Mutation: MeetingLimits.maxRecordingSeconds, set it to 3 * 3600 -> RED.
    func testTheRecordingCapStaysUnderTheDiarizationCap() throws {
        let daemon = TimeInterval(try goDiarSeconds())
        XCTAssertLessThan(MeetingLimits.maxRecordingSeconds + 10, daemon)
        XCTAssertGreaterThan(MeetingLimits.maxRecordingSeconds, daemon - 300, "no reason to stop much earlier than the daemon can use")
    }

    /// Mutation: MeetingLimits.reachedCap, change `>=` to `>` -> RED.
    func testTheCapIsReachedAtTheLimit() {
        XCTAssertFalse(MeetingLimits.reachedCap(elapsed: MeetingLimits.maxRecordingSeconds - 0.01))
        XCTAssertTrue(MeetingLimits.reachedCap(elapsed: MeetingLimits.maxRecordingSeconds))
        XCTAssertTrue(MeetingLimits.reachedCap(elapsed: MeetingLimits.maxRecordingSeconds + 5))
    }

    func testTextIsCutToTheDaemonsCharacterCaps() {
        let long = String(repeating: "я", count: 120)
        XCTAssertEqual(MeetingLimits.clamp(long, to: MeetingLimits.labelMax).unicodeScalars.count, 80)
        XCTAssertEqual(MeetingLimits.clamp("  Ann  ", to: 80), "Ann")
        XCTAssertEqual(MeetingLimits.clamp("short", to: 80), "short")
        XCTAssertEqual(MeetingLimits.clamp("", to: 80), "")
        // an emoji family is several scalars: the cut counts what the daemon counts (runes)
        let family = String(repeating: "👨‍👩‍👧", count: 40)
        XCTAssertLessThanOrEqual(MeetingLimits.clamp(family, to: 80).unicodeScalars.count, 80)
    }

    func testTheMeetingTitleNamesTheSource() {
        XCTAssertEqual(MeetingLimits.title(forSource: "oxpulse"), "OxPulse call")
        XCTAssertEqual(MeetingLimits.title(forSource: "zoom"), "Zoom call")
        XCTAssertEqual(MeetingLimits.title(forSource: "manual"), "")
        XCTAssertEqual(MeetingLimits.title(forSource: ""), "")
    }
}

final class MeetingCreateLimitsTests: XCTestCase {
    private func body(of request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    /// The daemon refuses a label over 80 characters or a source over 40 with a 400: a long display name must never
    /// make a recording fail to start (#252).
    /// Mutation: StudioClient.createMeeting, send `me` unclamped -> RED.
    func testCreateMeetingClampsEveryTextTheDaemonCaps() async throws {
        var sent: [String: Any] = [:]
        let client = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            sent = self.body(of: request)
            let json = #"{"id":"x","dir":"/d","status":"recording"}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let name = String(repeating: "Ж", count: 200)
        _ = try await client.createMeeting(title: String(repeating: "t", count: 300), source: String(repeating: "s", count: 90),
                                           me: name, them: "Other", speaker: "Speaker", echoRisk: false)
        let labels = try XCTUnwrap(sent["labels"] as? [String: String])
        XCTAssertEqual(labels["me"]?.unicodeScalars.count, 80)
        XCTAssertEqual((sent["source"] as? String)?.unicodeScalars.count, 40)
        XCTAssertEqual((sent["title"] as? String)?.unicodeScalars.count, 200)
        XCTAssertEqual(labels["them"], "Other")
        XCTAssertEqual(labels["speaker"], "Speaker")
    }
}

final class MeetingExporterTests: XCTestCase {
    private struct NotWritten: Error {}

    /// A fresh notes folder and defaults per test (the shim has no setUp/tearDown).
    private final class Fixture {
        let fm = FileManager.default
        let root: URL
        let defaults: UserDefaults

        init() {
            root = fm.temporaryDirectory.appendingPathComponent("ox-exporter-\(UUID().uuidString)", isDirectory: true)
            defaults = UserDefaults(suiteName: "ox-exporter-\(UUID().uuidString)")!
            MeetingSettings.setFolder(root, defaults)
        }

        func clean() { try? fm.removeItem(at: root) }

        func info(notes: String? = "notes v1", transcript: String? = "text v1") -> MeetingInfo {
            MeetingInfo(id: "m1", title: "Plan", started: Date(timeIntervalSince1970: 1_700_000_000), status: .done,
                        notesMD: notes, transcriptMD: transcript)
        }

        func copies() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        func exporter(stage: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) }) -> MeetingExporter {
            MeetingExporter(defaults: defaults, stage: stage)
        }

        func firstExport() throws -> URL {
            guard case .written(let dir) = exporter().export(info()) else { throw NotWritten() }
            return dir
        }

        func text(_ dir: URL, _ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    }

    /// Mutation: MeetingExporter.export, delete the `else if copied { return .alreadyExported }` branch -> RED (a second copy).
    func testAnExportedMeetingIsNotCopiedAgain() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        XCTAssertEqual(MeetingSettings.exportPath("m1", f.defaults), dir.path)
        XCTAssertEqual(MeetingSettings.exportHashes("m1", f.defaults), NotesExport.hashes(of: f.info()))
        XCTAssertEqual(f.exporter().export(f.info()), .alreadyExported)
        XCTAssertEqual(f.copies().count, 1)
    }

    func testStaleMeetingIsRefreshedInPlace() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        MeetingSettings.setExportStale("m1", true, f.defaults)
        let outcome = f.exporter().export(f.info(notes: "notes v2", transcript: "text v2"))
        XCTAssertEqual(outcome, .refreshed(dir))
        let notes = try f.text(dir, "notes.md")
        XCTAssertEqual(notes, "notes v2")
        XCTAssertFalse(MeetingSettings.exportStale(f.defaults).contains("m1"))
        XCTAssertEqual(f.copies().count, 1)
    }

    /// #260 N2: a refresh while the notes are pending has no notes text; the notes file's hash must survive, or the
    /// next refresh takes the file for the user's and never updates it.
    /// Mutation: MeetingExporter.export, replace the `.merging(…)` line with `NotesExport.hashes(of: info)` -> RED
    /// (the third export returns keptEdited).
    func testARefreshWithoutNotesKeepsTheNotesHash() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        MeetingSettings.setExportStale("m1", true, f.defaults)
        XCTAssertEqual(f.exporter().export(f.info(notes: nil, transcript: "text v2")), .refreshed(dir))
        XCTAssertEqual(MeetingSettings.exportHashes("m1", f.defaults)["notes.md"], NotesExport.hashes(of: f.info())["notes.md"])
        MeetingSettings.setExportStale("m1", true, f.defaults)
        XCTAssertEqual(f.exporter().export(f.info(notes: "notes v3", transcript: "text v3")), .refreshed(dir),
                       "the notes file is still recognised as ours")
        let notes = try f.text(dir, "notes.md")
        XCTAssertEqual(notes, "notes v3")
    }

    /// #260 N3: only "the folder was moved" earns a new copy. A staging failure is not that.
    /// Mutation: MeetingExporter.export, replace `catch NotesExport.ExportError.folderMoved` with a bare `catch {}`
    /// that falls through to the new copy -> RED.
    func testAStagingFailureDoesNotWriteASecondCopy() throws {
        let f = Fixture(); defer { f.clean() }
        _ = try f.firstExport()
        MeetingSettings.setExportStale("m1", true, f.defaults)
        struct Boom: Error {}
        let outcome = f.exporter(stage: { _, _ in throw Boom() }).export(f.info(notes: "notes v2", transcript: "text v2"))
        guard case .failed(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(f.copies().count, 1, "no second copy")
        XCTAssertTrue(MeetingSettings.exportStale(f.defaults).contains("m1"), "still stale, to try again")
    }

    func testAMovedFolderGetsANewCopyAndTheLedgerFollows() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        try f.fm.removeItem(at: dir)
        MeetingSettings.setExportStale("m1", true, f.defaults)
        guard case .written(let fresh) = f.exporter().export(f.info(notes: "notes v2")) else { return XCTFail("not written") }
        XCTAssertEqual(MeetingSettings.exportPath("m1", f.defaults), fresh.path)
        XCTAssertFalse(MeetingSettings.exportStale(f.defaults).contains("m1"))
        XCTAssertEqual(f.copies().count, 1)
    }

    /// A copy the user edited is left as it is, and the caller is told so (#260 N3).
    /// Mutation: MeetingExporter.export, return `.refreshed(dir)` for `.keptEdited` -> RED.
    func testAnEditedCopyIsLeftAlone() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        try "my own notes".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        MeetingSettings.setExportStale("m1", true, f.defaults)
        XCTAssertEqual(f.exporter().export(f.info(notes: "notes v2", transcript: "text v2")), .keptEdited(dir))
        let notes = try f.text(dir, "notes.md")
        let transcript = try f.text(dir, "transcript.md")
        XCTAssertEqual(notes, "my own notes")
        XCTAssertEqual(transcript, "text v1")
        XCTAssertTrue(MeetingSettings.exportStale(f.defaults).contains("m1"), "stays stale")
        XCTAssertEqual(MeetingExporter.Outcome.keptEdited(dir).noticeKey, .noticeMeetingCopyKept)
    }

    /// A copy made before the ledger existed has no path and no hashes: it is the user's, and no second copy appears
    /// beside it (#260 N3).
    /// Mutation: MeetingExporter.export, delete the `else if copied { return .keptEdited(nil) }` branch -> RED.
    func testAPreLedgerCopyGetsNoDuplicate() {
        let f = Fixture(); defer { f.clean() }
        MeetingSettings.markExported("m1", f.defaults)
        MeetingSettings.setExportStale("m1", true, f.defaults)
        XCTAssertEqual(f.exporter().export(f.info()), .keptEdited(nil))
        XCTAssertEqual(f.copies().count, 0)
        XCTAssertTrue(MeetingSettings.exportStale(f.defaults).contains("m1"))
    }

    /// Names renamed on a meeting whose notes were still pending made a transcript-only copy; when the notes arrive
    /// they must reach the same folder, not be taken for "already exported".
    /// Mutation: MeetingExporter.export, delete the `|| missingText` from `stale` -> RED.
    func testNotesThatArriveAfterATranscriptOnlyCopyAreAdded() throws {
        let f = Fixture(); defer { f.clean() }
        guard case .written(let dir) = f.exporter().export(f.info(notes: nil, transcript: "text v1")) else { return XCTFail("not written") }
        XCTAssertEqual(f.exporter().export(f.info(notes: nil, transcript: "text v1")), .alreadyExported, "nothing new yet")
        XCTAssertEqual(f.exporter().export(f.info(notes: "the notes", transcript: "text v1")), .refreshed(dir))
        let notes = try f.text(dir, "notes.md")
        XCTAssertEqual(notes, "the notes")
        XCTAssertEqual(f.copies().count, 1)
        XCTAssertEqual(f.exporter().export(f.info(notes: "the notes", transcript: "text v1")), .alreadyExported)
    }

    func testAnUnwritableFolderIsSaidInPlainWords() throws {
        let f = Fixture(); defer { f.clean() }
        try f.fm.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("not-a-folder")
        f.fm.createFile(atPath: file.path, contents: Data())
        MeetingSettings.setFolder(file, f.defaults)
        guard case .failed(let why) = f.exporter().export(f.info()) else { return XCTFail("expected a failure") }
        XCTAssertFalse(why.contains("Error Domain"), why)
        XCTAssertFalse(why.isEmpty)
        XCTAssertFalse(MeetingSettings.exported(f.defaults).contains("m1"), "not marked as copied")
        XCTAssertEqual(MeetingExporter.Outcome.failed(why).noticeKey, .noticeMeetingFailed)
    }

    func testWrittenAndRefreshedNeedNoNotice() {
        let url = URL(fileURLWithPath: "/tmp/x")
        XCTAssertNil(MeetingExporter.Outcome.written(url).noticeKey)
        XCTAssertNil(MeetingExporter.Outcome.refreshed(url).noticeKey)
        XCTAssertNil(MeetingExporter.Outcome.alreadyExported.noticeKey)
    }
}

final class MenuErrorCapTests: XCTestCase {
    /// A long download error made the menu as wide as the error (#247).
    /// Mutation: MeetingMenu.rows, pass `error` instead of `MeetingMenu.capped(error)` -> RED.
    func testALongInstallErrorIsCapped() {
        let long = String(repeating: "x", count: 500)
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(installError: long),
                                     autoStart: true, retention: .month)
        let titles = MeetingMenu.rows(state, text: { $0.rawValue + " %@" }).compactMap { row -> String? in
            if case .item(let title, _, _, _) = row { return title }
            return nil
        }
        let failed = titles.first { $0.hasPrefix("menu.meeting.install_failed") } ?? ""
        XCTAssertLessThan(failed.count, 160)
        XCTAssertTrue(failed.contains("…"))
    }
}
