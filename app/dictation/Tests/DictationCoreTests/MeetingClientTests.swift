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

    func testAnUnknownStatusOrMissingIDIsNotAMeeting() {
        XCTAssertNil(MeetingInfo.decode(Data(#"{"id":"x","status":"weird"}"#.utf8)))
        XCTAssertNil(MeetingInfo.decode(Data(#"{"status":"done"}"#.utf8)))
        XCTAssertNil(MeetingInfo.decode(Data("[]".utf8)))
        XCTAssertEqual(MeetingInfo.decodeList(Data(#"{"meetings":[{"id":"a","status":"done"},{"id":"b","status":"nope"}]}"#.utf8))?.count, 1)
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
