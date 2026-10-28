import Foundation
import XCTest
@testable import DictationCore

final class MeetingModelsTests: XCTestCase {
    func testDecodeAMeetingWithTexts() throws {
        let json = #"{"id":"20261023-143000-abcdef","dir":"/h/meetings/x","title":"Plan","started":"2026-10-23T14:30:00.123456-07:00","status":"transcribed","notes_pending":"model_missing","warnings":["no_system_audio"],"notes_md":"","transcript_md":"hi"}"#
        let m = try XCTUnwrap(MeetingInfo.decode(Data(json.utf8)))
        XCTAssertEqual(m.status, .transcribed)
        XCTAssertEqual(m.notesPending, "model_missing")
        XCTAssertTrue(m.heardNoSystemAudio)
        XCTAssertNil(m.notesMD, "an empty text is no text")
        XCTAssertEqual(m.transcriptMD, "hi")
        XCTAssertNotNil(m.started)
        XCTAssertTrue(m.settled)
    }

    func testAMissingIDIsNotAMeeting() {
        XCTAssertNil(MeetingInfo.decode(Data(#"{"status":"done"}"#.utf8)))
        XCTAssertNil(MeetingInfo.decode(Data(#"{"id":"x"}"#.utf8)), "no status at all is still not a meeting")
        XCTAssertNil(MeetingInfo.decode(Data("[]".utf8)))
    }

    /// A newer daemon may add a status (#231). The meeting must still be a meeting: shown, never acted on.
    /// Mutation: MeetingInfo.decode(_:), answer `return nil` for a status the enum does not know -> RED.
    func testAnUnknownStatusIsKeptNotDropped() throws {
        let m = try XCTUnwrap(MeetingInfo.decode(Data(#"{"id":"x","status":"future_state"}"#.utf8)))
        XCTAssertEqual(m.status, .unknown("future_state"))
        XCTAssertFalse(m.settled, "the app cannot tell the daemon is done: no delete, no retry")
        XCTAssertEqual(MeetingRowModel.status(of: m), .waiting, "shown as work in progress, with the existing words")
        XCTAssertEqual(Reconcile.action(for: m, exported: [], notesAvailable: true, currentID: nil), .skip)
        XCTAssertEqual(PlaybackGate.decide(audioDeleted: false, recordingRunning: false, status: m.status), .notReady)
        XCTAssertNil(MeetingRowModel.failureSentence(of: m))
        let list = try XCTUnwrap(MeetingInfo.decodeList(Data(#"{"meetings":[{"id":"a","status":"done"},{"id":"b","status":"nope"}]}"#.utf8)))
        XCTAssertEqual(list.map(\.id), ["a", "b"], "the list keeps the meeting it cannot classify")
    }

    /// One element that is not a string must not cost the array (#231): `no_system_audio` is what tells the user why
    /// the other side is silent.
    /// Mutation: MeetingInfo.decode(_:), `warnings` back to `as? [String] ?? []` -> RED.
    func testWarningsKeepTheStringsAroundAStrayElement() throws {
        let m = try XCTUnwrap(MeetingInfo.decode(Data(#"{"id":"x","status":"done","warnings":[7,"no_system_audio",null,{"a":1}]}"#.utf8)))
        XCTAssertEqual(m.warnings, ["no_system_audio"])
        XCTAssertTrue(m.heardNoSystemAudio)
    }

    func testStatusCarriesTheNotesBlock() throws {
        let json = #"{"version":"v1","idle":false,"notes":{"available":false,"reason_code":"model_missing","installing":true,"progress_pct":41}}"#
        let s = try XCTUnwrap(DaemonStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.notes, NotesStatus(available: false, reasonCode: "model_missing", installing: true, progressPercent: 41))
        XCTAssertFalse(s.notes.downloadWouldHelp, "while it downloads, another download does not help")
        XCTAssertEqual(DaemonStatus.decode(Data("{}".utf8))?.notes, NotesStatus(), "an older daemon reports no notes engine")
        XCTAssertTrue(NotesStatus(reasonCode: "model_missing").downloadWouldHelp)
        XCTAssertFalse(NotesStatus(reasonCode: "unsupported").downloadWouldHelp)
        XCTAssertFalse(NotesStatus(reasonCode: "engine_missing").downloadWouldHelp)
    }
}

final class MeetingClientTests: XCTestCase {
    private func client(_ answer: String, status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(answer.utf8), response)
        }
    }

    /// The daemon's guard answers 415 to a POST without `Content-Type: application/json`
    /// (CSRF defence), and URLSession sends no Content-Type for a bodiless POST. Every
    /// action POST must therefore carry the header and a `{}` body.
    /// Mutation: StudioClient.swift post(), put the header/body back inside `if let body`
    /// -> RED (no Content-Type, no body on finish, notes retry, voices retry, model install, stop).
    func testBodilessPostsStillCarryJSON() async throws {
        var seen: [URLRequest] = []
        let c = client(#"{"id":"20261023-143000-abcdef","status":"queued"}"#) { seen.append($0) }
        _ = try await c.finishMeeting(id: "20261023-143000-abcdef")
        try await c.retryMeetingNotes(id: "20261023-143000-abcdef")
        try await c.retryMeetingVoices(id: "20261023-143000-abcdef")
        try await c.installNotesModel()
        try await c.stopVoiceover(id: "j1")
        XCTAssertEqual(seen.map { $0.url?.path }, [
            "/v1/meetings/20261023-143000-abcdef/finish", "/v1/meetings/20261023-143000-abcdef/notes",
            "/v1/meetings/20261023-143000-abcdef/voices",
            "/v1/meetings/notes-model/install", "/v1/produce/j1/cancel",
        ])
        for request in seen {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "\(request.url?.path ?? "")")
            XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "{}", "\(request.url?.path ?? "")")
        }
    }

    func testRetentionPutKeepsItsOwnBodyAndJSONHeader() async throws {
        var seen: URLRequest?
        let c = client("{}") { seen = $0 }
        try await c.setMeetingRetention(days: 7)
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["retention_days"] as? Int, 7)
    }

    func testCreateSendsLabelsAndEchoRiskAndNeedsTheDir() async throws {
        var seen: URLRequest?
        let c = client(#"{"id":"20261023-143000-abcdef","dir":"/d","status":"recording"}"#) { seen = $0 }
        let m = try await c.createMeeting(title: "Zoom call", source: "zoom", me: "Anatoly", them: "Other", echoRisk: true)
        XCTAssertEqual(m.dir, "/d")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual((body?["labels"] as? [String: String])?["me"], "Anatoly")
        XCTAssertEqual(body?["echo_risk"] as? Bool, true)
        let noDir = client(#"{"id":"20261023-143000-abcdef","status":"recording"}"#)
        do { _ = try await noDir.createMeeting(title: "", source: "", me: "a", them: "b", echoRisk: false); XCTFail("a create without a dir cannot be recorded into") }
        catch { XCTAssertEqual(error as? StudioError, .badResponse) }
    }

    func testMeetingWithTextsAsksForThem() async throws {
        var seen: URLRequest?
        let c = client(#"{"id":"a","status":"done","notes_md":"n"}"#) { seen = $0 }
        let m = try await c.meeting(id: "a", withTexts: true)
        XCTAssertEqual(m.notesMD, "n")
        XCTAssertEqual(seen?.url?.query, "include=notes,transcript")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/a")
    }

    /// Create and finish already succeeded in the daemon when the answer comes back: an unknown status must not throw.
    /// Mutation: MeetingInfo.decode(_:), `return nil` for an unknown status -> RED.
    func testCreateAndFinishSurviveAnUnknownStatus() async throws {
        let created = try await client(#"{"id":"20261023-143000-abcdef","dir":"/d","status":"future_state"}"#)
            .createMeeting(title: "", source: "", me: "a", them: "b", echoRisk: false)
        XCTAssertEqual(created.status, .unknown("future_state"))
        let finished = try await client(#"{"id":"20261023-143000-abcdef","status":"future_state"}"#).finishMeeting(id: "20261023-143000-abcdef")
        XCTAssertEqual(finished.status, .unknown("future_state"))
    }

    /// The texts of a long call are read from disk by a daemon that may be busy transcribing: more than the 10 s of a
    /// status read (#231). Without texts the read stays quick.
    /// Mutation: StudioClient.meeting(id:withTexts:), drop the `request.timeoutInterval = Self.meetingTextsTimeout` line -> RED.
    func testReadingTheTextsHasALongerTimeout() async throws {
        var withTexts: URLRequest?, plain: URLRequest?
        _ = try await client(#"{"id":"a","status":"done"}"#) { withTexts = $0 }.meeting(id: "a", withTexts: true)
        _ = try await client(#"{"id":"a","status":"done"}"#) { plain = $0 }.meeting(id: "a")
        XCTAssertEqual(withTexts?.timeoutInterval, StudioClient.meetingTextsTimeout)
        XCTAssertGreaterThan(StudioClient.meetingTextsTimeout, StudioClient.quickTimeout)
        XCTAssertEqual(plain?.timeoutInterval, StudioClient.quickTimeout)
    }

    func testRetentionIsAPutAndARefusalCarriesTheDaemonsWords() async throws {
        var seen: URLRequest?
        try await client("{}") { seen = $0 }.setMeetingRetention(days: 0)
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/settings")
        let refused = client(#"{"error":{"message":"not enough free disk space: 4 GB needed, 1 GB free"}}"#, status: 409)
        do { try await refused.installNotesModel(); XCTFail("want a refusal") }
        catch { XCTAssertTrue("\(error)".contains("free disk space")) }
    }
}
