import Foundation
import XCTest
@testable import DictationCore

/// Why a meeting or the notes failed, in the user's language. The daemon sends a stable code (`fail_reason`,
/// `install_error_code`, `reason_code`) beside its English text; the window shows only its own sentence for the code.
final class MeetingFailureTests: XCTestCase {
    private func failed(_ code: String?) -> MeetingInfo {
        var info = MeetingInfo(id: "a", status: .failed)
        info.failReason = code
        info.error = "stt: model ggml-x.bin not found at /Users/someone/.ox-say"
        return info
    }

    private func notesFailed(_ code: String?) -> MeetingInfo {
        var info = MeetingInfo(id: "b", status: .transcribed, notesPending: "failed")
        info.failReason = code
        info.error = "the notes model failed to start: engine exited during startup"
        return info
    }

    private let key: (L10nKey) -> String = { $0.rawValue }

    // MARK: a failed recording

    /// Mutation: MeetingRowModel.failureSentence, return `text(.meetingFailedGeneric)` for `.failed` without reading
    /// `info.failReason` -> RED (the window ignores the code).
    func testEachCodeOfAFailedRecordingHasItsOwnSentence() {
        let expected: [(String, L10nKey)] = [
            ("speech_model_missing", .meetingFailedSpeechModel),
            ("speech_busy", .meetingFailedSpeechBusy),
            ("speech_failed", .meetingFailedSpeech),
            ("no_transcript", .meetingFailedNoTranscript),
            ("storage", .meetingFailedStorage),
            ("disk_full", .meetingFailedDiskFull),
        ]
        for (code, want) in expected {
            XCTAssertEqual(MeetingFailure.key(code: code, notes: false), want, code)
            XCTAssertEqual(MeetingRowModel.failureSentence(of: failed(code), text: key), want.rawValue, code)
        }
    }

    func testAnUnknownOrMissingCodeOfAFailedRecordingIsTheGeneralSentence() {
        for code in [nil, "", "from_the_future", "notes_engine_start"] as [String?] {
            XCTAssertEqual(MeetingRowModel.failureSentence(of: failed(code), text: key), "meeting.failed.generic", "\(code ?? "nil")")
        }
    }

    // MARK: failed notes

    func testEachCodeOfFailedNotesHasItsOwnSentence() {
        let expected: [(String, L10nKey)] = [
            ("notes_engine_start", .meetingNotesEngineStart),
            ("notes_engine_verify", .meetingNotesEngineVerify),
            ("notes_engine_timeout", .meetingNotesEngineTimeout),
            ("notes_empty", .meetingNotesEmpty),
            ("notes_failed", .meetingNotesFailed),
            ("storage", .meetingNotesStorage),
            ("disk_full", .meetingNotesDiskFull),
        ]
        for (code, want) in expected {
            XCTAssertEqual(MeetingFailure.key(code: code, notes: true), want, code)
            XCTAssertEqual(MeetingRowModel.failureSentence(of: notesFailed(code), text: key), want.rawValue, code)
        }
    }

    func testAnUnknownCodeOfFailedNotesIsTheGeneralNotesSentence() {
        for code in [nil, "", "from_the_future", "speech_busy"] as [String?] {
            XCTAssertEqual(MeetingRowModel.failureSentence(of: notesFailed(code), text: key), "meeting.notes.failed", "\(code ?? "nil")")
        }
    }

    func testTheDaemonsEnglishTextIsNeverShown() {
        for info in [failed("speech_busy"), failed(nil), notesFailed("notes_engine_verify"), notesFailed(nil)] {
            let sentence = MeetingRowModel.failureSentence(of: info, text: { $0.rawValue }) ?? ""
            XCTAssertFalse(sentence.contains(info.error ?? "?"), sentence)
        }
    }

    func testTheCodeIsDecodedFromTheListAndTheDetail() {
        let json = #"{"id":"a","status":"failed","error":"boom","fail_reason":"speech_busy"}"#
        XCTAssertEqual(MeetingInfo.decode(Data(json.utf8))?.failReason, "speech_busy")
        let list = #"{"meetings":[{"id":"a","status":"failed","fail_reason":"storage"},{"id":"b","status":"done"}]}"#
        let infos = MeetingInfo.decodeList(Data(list.utf8))
        XCTAssertEqual(infos?.map(\.failReason), ["storage", nil])
    }

    // MARK: the notes writer

    /// Mutation: NotesWriterState.of, drop the `installError` branch (return `.missing`) -> RED.
    func testAFailedDownloadSaysWhyNextToTheDownloadAction() {
        let cases: [(String?, L10nKey)] = [
            ("network", .settingsNotesWriterDownloadNetwork),
            ("disk_full", .settingsNotesWriterDownloadDisk),
            ("checksum", .settingsNotesWriterDownloadChecksum),
            ("server", .settingsNotesWriterDownloadServer),
            ("other", .settingsNotesWriterDownloadOther),
            ("from_the_future", .settingsNotesWriterDownloadOther),
            (nil, .settingsNotesWriterDownloadOther),
        ]
        for (code, want) in cases {
            let status = NotesStatus(available: false, reasonCode: "model_missing", installError: "The download failed: curl: (6)",
                                     installErrorCode: code)
            XCTAssertEqual(NotesWriterState.of(status), .downloadFailed(want), "\(code ?? "nil")")
        }
    }

    func testWithoutAFailureTheMissingModelIsJustMissing() {
        XCTAssertEqual(NotesWriterState.of(NotesStatus(available: false, reasonCode: "model_missing")), .missing)
        XCTAssertEqual(NotesWriterState.of(NotesStatus(available: false, reasonCode: "model_missing", installing: true, progressPercent: 40,
                                                       installError: "old", installErrorCode: "network")), .downloading(percent: 40))
    }

    func testTheDownloadErrorCodeIsDecodedFromStatus() {
        let json = #"{"notes":{"available":false,"reason_code":"model_missing","install_error":"The download failed: x","install_error_code":"disk_full"}}"#
        let status = DaemonStatus.decode(Data(json.utf8))
        XCTAssertEqual(status?.notes.installErrorCode, "disk_full")
        XCTAssertEqual(status?.notes.installError, "The download failed: x")
    }

    /// Mutation: NotesWriterState.of, check `status.available` before `reasonCode == "notes_engine_failed"` and return
    /// `.ready` -> RED (the failure is invisible again).
    func testANotesEngineThatFailedIsSaidWhileTheNotesStayAvailable() {
        let status = NotesStatus(available: true, reasonCode: "notes_engine_failed")
        XCTAssertEqual(NotesWriterState.of(status), .engineFailed(.settingsNotesWriterEngineFailed))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(available: true)), .ready, "a healthy writer is still ready")
        XCTAssertEqual(NotesWriterState.of(NotesStatus(available: true, reasonCode: "something_else")), .ready)
        XCTAssertTrue(status.available, "the daemon keeps the notes available; the flag is not touched")
    }

    // MARK: what the window shows, and the action beside it

    /// One function answers "what does this meeting's failure look like" for the header, the notes callout and the list.
    /// Mutation: MeetingFailureNotice.of, drop the `.transcribed` case (return nil) -> RED (failed notes show nothing).
    /// Mutation: MeetingFailureNotice.of, build the `.failed` sentence with `notes: true` -> RED.
    func testOneNoticeCoversAFailedRecordingAndFailedNotes() throws {
        let rec = try XCTUnwrap(MeetingFailureNotice.of(failed("speech_busy"), text: key))
        XCTAssertEqual(rec, MeetingFailureNotice(sentence: "meeting.failed.speech_busy", notes: false, canRetry: true))
        let notes = try XCTUnwrap(MeetingFailureNotice.of(notesFailed("notes_engine_timeout"), text: key))
        XCTAssertEqual(notes, MeetingFailureNotice(sentence: "meeting.notes.failed.engine_timeout", notes: true, canRetry: true))
        for status: MeetingInfo.Status in [.recording, .queued, .transcribing, .summarizing, .done, .unknown("x")] {
            XCTAssertNil(MeetingFailureNotice.of(MeetingInfo(id: "n", status: status, notesPending: "failed"), text: key), "\(status)")
        }
        XCTAssertNil(MeetingFailureNotice.of(MeetingInfo(id: "t", status: .transcribed, notesPending: "model_missing"), text: key),
                     "a missing model is the other callout, not a failure")
    }

    /// "Try Again" is offered exactly where the daemon's Retry can do something: every failed recording with its audio
    /// (or a transcript) and every failed notes run; not when retention removed the audio, and not for a missing speech
    /// model (the daemon finishes the recording by itself once it is installed, and a retry would fail the same way).
    /// Mutation: MeetingFailureNotice.of, `canRetry` for `.failed` always `true` -> RED (audio gone / model missing rows).
    /// Mutation: same, `canRetry` always `false` -> RED (nothing to press).
    func testTryAgainIsOfferedWhereItCanHelp() throws {
        for code in ["speech_busy", "speech_failed", "no_transcript", "storage", "disk_full", nil] as [String?] {
            XCTAssertEqual(MeetingFailureNotice.of(failed(code), text: key)?.canRetry, true, "\(code ?? "nil")")
        }
        XCTAssertEqual(MeetingFailureNotice.of(failed("speech_model_missing"), text: key)?.canRetry, false)
        var gone = failed("speech_failed")
        gone.audioDeleted = true
        XCTAssertEqual(MeetingFailureNotice.of(gone, text: key)?.canRetry, false)
        var goneNotes = notesFailed("notes_empty")
        goneNotes.audioDeleted = true
        XCTAssertEqual(MeetingFailureNotice.of(goneNotes, text: key)?.canRetry, true, "the transcript stands: the notes can be written again")
    }

    /// The advice in a sentence names an action that exists: "Try Again" only where the button is offered, "Reinstall
    /// OxSay" only for the missing speech model.
    /// Mutation: Resources/en.lproj, put "Press Try Again." on the `speech_model_missing` sentence -> RED.
    func testASentenceOnlyAdvisesAnActionThatIsOffered() throws {
        let en = try values(of: "en"), ru = try values(of: "ru")
        let recordingCodes = ["speech_model_missing", "speech_busy", "speech_failed", "no_transcript", "storage", "disk_full"]
        for code in recordingCodes {
            let notice = MeetingFailureNotice.of(failed(code), text: { try! XCTUnwrap(en[$0.rawValue]) })
            let sentence = try XCTUnwrap(notice).sentence
            let sentenceRu = try XCTUnwrap(MeetingFailureNotice.of(failed(code), text: { try! XCTUnwrap(ru[$0.rawValue]) })).sentence
            XCTAssertEqual(sentence.contains("Try Again"), notice?.canRetry, "\(code): the advice must match the button")
            XCTAssertEqual(sentenceRu.contains("«Повторить»"), notice?.canRetry, "\(code) ru")
        }
        XCTAssertTrue(v(en, "meeting.failed.speech_model_missing").contains("Reinstall OxSay"))
        XCTAssertTrue(v(ru, "meeting.failed.speech_model_missing").contains("Переустановите OxSay"))
        // The button says what the sentences say.
        XCTAssertEqual(en["common.retry"], "Try Again")
        XCTAssertEqual(en["meeting.notes.retry"], "Try Again")
        XCTAssertEqual(ru["common.retry"], "Повторить")
        XCTAssertEqual(ru["meeting.notes.retry"], "Повторить")
    }

    /// The Settings row cannot retry anything: it points to the meeting. The notes engine has one name everywhere the
    /// user reads it: the Settings row's own term.
    /// Mutation: Resources/en.lproj, put "Retry the notes." back on settings.notes_writer.engine_failed -> RED.
    func testSettingsPointsToTheMeetingAndTheEngineHasOneName() throws {
        let en = try values(of: "en"), ru = try values(of: "ru")
        let enSettings = v(en, "settings.notes_writer.engine_failed"), ruSettings = v(ru, "settings.notes_writer.engine_failed")
        XCTAssertTrue(enSettings.contains("Open the meeting"), enSettings)
        XCTAssertFalse(enSettings.lowercased().contains("retry the notes"), enSettings)
        XCTAssertTrue(ruSettings.contains("Откройте встречу"), ruSettings)
        let term = v(en, "settings.notes_writer").lowercased(), termRu = v(ru, "settings.notes_writer").lowercased()
        XCTAssertEqual(term, "notes writer")
        for k in ["meeting.notes.failed.engine_start", "meeting.notes.failed.engine_verify", "meeting.notes.failed.engine_timeout",
                  "meeting.notes.failed.empty", "settings.notes_writer.engine_failed"] {
            XCTAssertTrue(v(en, k).lowercased().contains(term), "\(k) en: \(en[k] ?? "")")
            XCTAssertTrue(v(ru, k).lowercased().contains(termRu), "\(k) ru: \(ru[k] ?? "")")
            XCTAssertFalse(v(en, k).contains("notes model"), k)
            XCTAssertFalse(v(ru, k).contains("модель для заметок"), k)
        }
    }

    /// A menu row is one short line.
    /// Mutation: Resources/en.lproj, lengthen menu.meeting.install_failed.server past 60 characters -> RED.
    func testTheMenuSentencesStayShort() throws {
        let keys: [L10nKey] = [.menuMeetingInstallFailedNetwork, .menuMeetingInstallFailedDisk, .menuMeetingInstallFailedChecksum,
                               .menuMeetingInstallFailedServer, .menuMeetingInstallFailedOther]
        for locale in ["en", "ru"] {
            let all = try values(of: locale)
            for k in keys { XCTAssertLessThanOrEqual(v(all, k.rawValue).count, 60, "\(locale) \(k.rawValue)") }
        }
    }

    // MARK: the strings

    /// Every sentence this file maps to exists in both languages, is a real sentence in each, and is not the other's.
    func testEverySentenceExistsInEnglishAndRussian() throws {
        let keys: [L10nKey] = [
            .meetingFailedSpeechModel, .meetingFailedSpeechBusy, .meetingFailedSpeech, .meetingFailedNoTranscript, .meetingFailedStorage, .meetingFailedDiskFull,
            .meetingNotesEngineStart, .meetingNotesEngineVerify, .meetingNotesEngineTimeout, .meetingNotesEmpty, .meetingNotesStorage, .meetingNotesDiskFull,
            .settingsNotesWriterEngineFailed, .settingsNotesWriterDownloadNetwork, .settingsNotesWriterDownloadDisk,
            .settingsNotesWriterDownloadChecksum, .settingsNotesWriterDownloadServer, .settingsNotesWriterDownloadOther,
            .menuMeetingInstallFailedNetwork, .menuMeetingInstallFailedDisk, .menuMeetingInstallFailedChecksum,
            .menuMeetingInstallFailedServer, .menuMeetingInstallFailedOther,
        ]
        let en = try values(of: "en"), ru = try values(of: "ru")
        for k in keys {
            let e = try XCTUnwrap(en[k.rawValue], "\(k.rawValue) missing in en"), r = try XCTUnwrap(ru[k.rawValue], "\(k.rawValue) missing in ru")
            XCTAssertFalse(e.isEmpty || r.isEmpty, k.rawValue)
            XCTAssertNotEqual(e, r, k.rawValue)
            XCTAssertNil(e.range(of: "[А-Яа-яЁё]", options: .regularExpression), "en holds Russian: \(e)")
            XCTAssertNotNil(r.range(of: "[А-Яа-яЁё]", options: .regularExpression), "ru holds no Russian: \(r)")
            XCTAssertFalse(e.contains("%"), k.rawValue)
        }
    }

    private func v(_ d: [String: String], _ k: String) -> String { d[k] ?? "" }

    private func values(of locale: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings"), encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.range(of: #"^"([A-Za-z0-9._]+)"\s*=\s*"(.*)";\s*$"#, options: .regularExpression) else { continue }
            let pair = String(line[eq])
            let parts = pair.components(separatedBy: "\" = \"")
            guard parts.count == 2 else { continue }
            out[String(parts[0].dropFirst())] = String(parts[1].dropLast(2))
        }
        return out
    }
}
