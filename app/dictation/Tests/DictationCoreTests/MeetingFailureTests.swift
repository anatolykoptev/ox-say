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

    // MARK: the strings

    /// Every sentence this file maps to exists in both languages, is a real sentence in each, and is not the other's.
    func testEverySentenceExistsInEnglishAndRussian() throws {
        let keys: [L10nKey] = [
            .meetingFailedSpeechModel, .meetingFailedSpeechBusy, .meetingFailedSpeech, .meetingFailedNoTranscript, .meetingFailedStorage,
            .meetingNotesEngineStart, .meetingNotesEngineVerify, .meetingNotesEngineTimeout, .meetingNotesEmpty, .meetingNotesStorage,
            .settingsNotesWriterEngineFailed, .settingsNotesWriterDownloadNetwork, .settingsNotesWriterDownloadDisk,
            .settingsNotesWriterDownloadChecksum, .settingsNotesWriterDownloadOther,
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
