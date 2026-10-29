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
        XCTAssertEqual(assess(elapsed: 25, playingFor: SystemAudioGuard.playingBeforeVerdict), .silentTap)
    }

    func testNothingPlayingIsNotASilentTap() {
        XCTAssertEqual(assess(elapsed: 30, playingFor: 0), .otherSideQuiet)
        XCTAssertEqual(assess(elapsed: 12, playingFor: SystemAudioGuard.playingBeforeVerdict - 0.5), .waiting)
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

    private func goConstant(_ file: String, _ name: String) throws -> Int {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
        let re = try NSRegularExpression(pattern: name + #"\s*=\s*(\d+)"#)
        let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(name) not found in \(file)")
        return Int(text[Range(m.range(at: 1), in: text)!])!
    }

    /// The app's caps are the daemon's: a cap raised in Go and not here would cut text for nothing, one lowered in Go
    /// and not here would be a 400 again (#252).
    /// Mutation: MeetingLimits.labelMax, set it to 81 (likewise titleMax, sourceMax, nameMax) -> RED.
    func testTheCapsAreTheDaemonsCaps() throws {
        let titleMax = try goConstant("internal/daemon/meetings_http.go", "maxTitleChars")
        XCTAssertEqual(MeetingLimits.titleMax, titleMax)
        let labelMax = try goConstant("internal/daemon/meetings_http.go", "maxLabelChars")
        XCTAssertEqual(MeetingLimits.labelMax, labelMax)
        let sourceMax = try goConstant("internal/daemon/meetings_http.go", "maxSourceChars")
        XCTAssertEqual(MeetingLimits.sourceMax, sourceMax)
        let nameMax = try goConstant("internal/meeting/speakers.go", "MaxNameRunes")
        XCTAssertEqual(MeetingLimits.nameMax, nameMax)
    }

    /// The daemon counts runes; the cut must not leave half a character (a family emoji, a base letter without its
    /// accent) at the end.
    /// Mutation: MeetingLimits.clamp, cut `trimmed.unicodeScalars.prefix(limit)` instead of whole characters -> RED.
    func testTheCutKeepsWholeCharacters() {
        let family = "👨‍👩‍👧"
        XCTAssertEqual(family.unicodeScalars.count, 5)
        let text = String(repeating: "a", count: 78) + family
        let cut = MeetingLimits.clamp(text, to: 80)
        XCTAssertEqual(cut, String(repeating: "a", count: 78), "a character that does not fit is dropped whole")
        let accents = String(repeating: "e\u{301}", count: 50)
        let cutAccents = MeetingLimits.clamp(accents, to: 81)
        XCTAssertEqual(cutAccents.unicodeScalars.count, 80)
        XCTAssertEqual(cutAccents.count, 40)
    }

    /// What a field holds while typing: cut, never trimmed (a trailing space is the next word's start).
    /// Mutation: MeetingLimits.cap, trim the result -> RED.
    func testCapKeepsSpacesWhileTyping() {
        XCTAssertEqual(MeetingLimits.cap("ab  ", to: 3), "ab ")
        XCTAssertEqual(MeetingLimits.cap(" ab", to: 10), " ab")
        XCTAssertEqual(MeetingLimits.cap(String(repeating: "я", count: 90), to: 80).unicodeScalars.count, 80)
    }

    func testTheMeetingTitleNamesTheSource() {
        XCTAssertEqual(MeetingLimits.title(forSource: "oxpulse"), "OxPulse call")
        XCTAssertEqual(MeetingLimits.title(forSource: "whatsapp"), "WhatsApp call")
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

        func exporter(stage: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) },
                      replace: ((URL, URL) throws -> Void)? = nil) -> MeetingExporter {
            MeetingExporter(defaults: defaults, stage: stage, replace: replace)
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

    /// #260.N4 follow-up: the second replace fails after notes.md is already new. The ledger takes the new notes.md
    /// as ours, so the next refresh (replace working again) finishes transcript.md instead of answering `.keptEdited`
    /// forever.
    /// Mutation: MeetingExporter.export, delete the `catch let partial as NotesExport.PartialRefresh` branch's ledger
    /// write (`setExportHashes`) -> RED (the retry answers keptEdited and the transcript stays old).
    func testAPartialRefreshFailureIsFinishedByTheNextRefresh() throws {
        let f = Fixture(); defer { f.clean() }
        let dir = try f.firstExport()
        MeetingSettings.setExportStale("m1", true, f.defaults)
        let v2 = f.info(notes: "notes v2", transcript: "text v2")
        var calls = 0
        let failing: (URL, URL) throws -> Void = { original, temp in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            _ = try FileManager.default.replaceItemAt(original, withItemAt: temp)
        }
        guard case .failed(let why) = f.exporter(replace: failing).export(v2) else { return XCTFail("the partial failure must be reported") }
        XCTAssertFalse(why.isEmpty)
        let notesAfterFailure = try f.text(dir, "notes.md"), transcriptAfterFailure = try f.text(dir, "transcript.md")
        XCTAssertEqual(notesAfterFailure, "notes v2")
        XCTAssertEqual(transcriptAfterFailure, "text v1")
        XCTAssertTrue(MeetingSettings.exportStale(f.defaults).contains("m1"), "still stale, to try again")
        let again = f.exporter().export(v2)
        XCTAssertEqual(again, .refreshed(dir), "the new notes.md is ours: \(again)")
        let notesAfterRetry = try f.text(dir, "notes.md"), transcriptAfterRetry = try f.text(dir, "transcript.md")
        XCTAssertEqual(notesAfterRetry, "notes v2")
        XCTAssertEqual(transcriptAfterRetry, "text v2")
        XCTAssertEqual(f.copies().count, 1, "no second copy")
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

    // MARK: what the daemon's checkName / checkText refuse (#361.5, #361.6)

    private func goSource(_ file: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
    }

    private func hexValues(in text: String, pattern: String) throws -> [UInt32] {
        let re = try NSRegularExpression(pattern: pattern)
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            UInt32(text[Range($0.range(at: 1), in: text)!], radix: 16)
        }
    }

    private func goFunc(_ source: String, _ name: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func \(name)("), "\(name) not found")
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The character sets the app strips are the daemon's: read from the Go source, so a set widened there and not
    /// here would be a 400 again.
    /// Mutation: MeetingLimits.bidiControls, change `0x2069` to `0x2068` (or nameSeparators `0x2029` to `0x202F`) -> RED.
    func testTheRefusedCharacterSetsAreTheDaemons() throws {
        let speakers = try goSource("internal/meeting/speakers.go")
        let bidi = try goFunc(speakers, "isBidiControl")
        let bounds = try hexValues(in: bidi, pattern: #"0x([0-9A-Fa-f]{4})"#)
        XCTAssertEqual(bounds, MeetingLimits.bidiControls.flatMap { [$0.lowerBound, $0.upperBound] })
        let check = try goFunc(speakers, "checkName")
        // the Go source holds the two separators as literal characters between quotes
        let quoted = try NSRegularExpression(pattern: "'([^'\\n])'").matches(in: check, range: NSRange(check.startIndex..., in: check))
            .map { check[Range($0.range(at: 1), in: check)!].unicodeScalars.first!.value }
        XCTAssertEqual(quoted, MeetingLimits.nameSeparators)
        XCTAssertTrue(check.contains("unicode.IsControl(r)"), "controls are refused")
        XCTAssertTrue(check.contains("isBidiControl(r)"))
        XCTAssertTrue(check.contains("unicode.IsLetter(r) || unicode.IsDigit(r)"), "a name needs a letter or a digit")
        let http = try goFunc(try goSource("internal/daemon/meetings_http.go"), "checkText")
        XCTAssertTrue(http.contains("meeting.HasBidiControl(text)"), "titles, labels and sources: bidi controls only")
        let clean = try goFunc(try goSource("internal/daemon/meetings_http.go"), "cleanText")
        XCTAssertTrue(clean.contains("unicode.IsControl(r)"), "the daemon turns controls in a title into a space itself")
    }

    /// Mutation: MeetingLimits.isBidiControl, `contains` -> `false` -> RED (the boundaries stay in).
    func testBidiControlsAreRemovedAtTheBoundaries() {
        for v: UInt32 in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let c = String(Unicode.Scalar(v)!)
            XCTAssertEqual(MeetingLimits.withoutBidiControls("a\(c)b"), "ab", String(v, radix: 16))
        }
        for v: UInt32 in [0x2029, 0x202F, 0x2065, 0x206A, 0x200E] {  // neighbours (and LRM, which the daemon allows) stay
            let c = String(Unicode.Scalar(v)!)
            XCTAssertEqual(MeetingLimits.withoutBidiControls("a\(c)b"), "a\(c)b", String(v, radix: 16))
        }
    }

    /// A title, label or source goes out without the controls checkText refuses.
    /// Mutation: MeetingLimits.clamp, drop `withoutBidiControls(text)` -> RED.
    func testClampDropsTextDirectionControls() {
        XCTAssertEqual(MeetingLimits.clamp("\u{202E}Standup\u{2069}", to: 200), "Standup")
        XCTAssertEqual(MeetingLimits.clamp("\u{202E}", to: 80), "")
    }

    func testSpeakerNameRules() {
        XCTAssertEqual(MeetingLimits.speakerName("  Anna\u{202E}\tLee \u{2029}"), "Anna Lee")
        XCTAssertTrue(MeetingLimits.hasLetterOrDigit("Анна"))
        XCTAssertTrue(MeetingLimits.hasLetterOrDigit("?7?"))
        XCTAssertFalse(MeetingLimits.hasLetterOrDigit("?! -_"))
        XCTAssertFalse(MeetingLimits.hasLetterOrDigit("😀"))
        XCTAssertFalse(MeetingLimits.hasLetterOrDigit(""))
    }

    /// One Character longer than the limit: `cap` gives "" (nothing fits), `cap(keeping:)` refuses the edit.
    /// Mutation: MeetingLimits.cap(_:to:keeping:), return `cut` unconditionally -> RED.
    func testAHugeFirstCharacterIsRefusedNotErased() {
        let huge = "e" + String(repeating: "\u{301}", count: 70)
        XCTAssertEqual(MeetingLimits.cap(huge, to: 60), "", "the primitive is unchanged")
        XCTAssertEqual(MeetingLimits.cap(huge, to: 60, keeping: "Ivan"), "Ivan")
        XCTAssertEqual(MeetingLimits.cap("", to: 60, keeping: "Ivan"), "", "an emptied field is an edit")
        XCTAssertEqual(MeetingLimits.cap("Ivan the Terrible", to: 4, keeping: "Ivan"), "Ivan")
    }

    /// While an input method holds marked text in the field the text is left alone; the cut follows at the commit.
    /// Mutation: MeetingLimits.live, ignore `marked` -> RED.
    func testNoCutWhileAnInputMethodComposes() {
        let long = String(repeating: "a", count: 70)
        XCTAssertEqual(MeetingLimits.live(long, previous: "x", to: 60, marked: true), long)
        XCTAssertEqual(MeetingLimits.live(long, previous: "x", to: 60, marked: false), String(repeating: "a", count: 60))
        XCTAssertEqual(MeetingLimits.live("e" + String(repeating: "\u{301}", count: 70), previous: "Ivan", to: 60, marked: false), "Ivan")
    }

    /// The Speakers prompt cuts as the user types, like the other two fields; the AppKit glue (an
    /// NSTextFieldDelegate on every name field) is not built by the test target, so it is pinned as text.
    /// Mutation: SpeakersPrompt, delete `field.delegate = nameCap` -> RED.
    func testTheSpeakersPromptCapsWhileTyping() throws {
        let src = try MeetingWiringTests.stripComments(String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/SpeakersPrompt.swift"), encoding: .utf8))
        XCTAssertTrue(src.contains("field.delegate = nameCap"))
        XCTAssertTrue(src.contains("func controlTextDidChange"))
        XCTAssertTrue(src.contains("MeetingLimits.live(field.stringValue"))
        XCTAssertTrue(src.contains("hasMarkedText()"), "a composition is not cut")
        XCTAssertTrue(src.contains("MeetingLimits.nameMax"))
    }
}
