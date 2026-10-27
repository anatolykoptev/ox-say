import Foundation
import XCTest
@testable import DictationCore

/// The calls the main window adds to the meeting client: rename, delete and the daemon's settings.
final class MeetingClientWindowTests: XCTestCase {
    private func client(_ answer: String, status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(answer.utf8), response)
        }
    }

    /// The daemon's PATCH wants `{"title": …}` and, like every non-GET, the JSON content type.
    /// Mutation: MeetingClient.renameMeeting, `"title": ` -> `"name": ` (or drop the Content-Type) -> RED.
    func testRenameIsAPatchWithTheTitleAndTheJSONHeader() async throws {
        var seen: URLRequest?
        let c = client(#"{"id":"20261023-143000-abcdef","title":"Roadmap","status":"done"}"#) { seen = $0 }
        let updated = try await c.renameMeeting(id: "20261023-143000-abcdef", title: "  Roadmap  ")
        XCTAssertEqual(seen?.httpMethod, "PATCH")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/20261023-143000-abcdef")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?.keys.sorted(), ["title"])
        XCTAssertEqual(body?["title"] as? String, "Roadmap", "the title is trimmed before it is sent")
        XCTAssertEqual(updated.title, "Roadmap")
    }

    /// The daemon answers 400 to a title over its cap; a long one is cut, never refused.
    func testRenameCutsATitleOverTheDaemonsCap() async throws {
        var seen: URLRequest?
        let c = client(#"{"id":"a","status":"done"}"#) { seen = $0 }
        _ = try await c.renameMeeting(id: "a", title: String(repeating: "я", count: MeetingLimits.titleMax + 40))
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual((body?["title"] as? String)?.unicodeScalars.count, MeetingLimits.titleMax)
    }

    /// A rename the daemon refuses (409: still being processed) reaches the caller with the daemon's words.
    func testARefusedRenameThrows() async {
        let c = client(#"{"error":{"message":"this meeting is still being recorded or processed; rename it when it is done"}}"#, status: 409)
        do { _ = try await c.renameMeeting(id: "a", title: "x"); XCTFail("a 409 must throw") }
        catch { XCTAssertEqual((error as? StudioError).map { if case .refused(let s, _) = $0 { return s } else { return 0 } }, 409) }
    }

    /// Mutation: MeetingClient.deleteMeeting, `httpMethod = "DELETE"` -> `"POST"` -> RED.
    func testDeleteIsADeleteOfTheMeeting() async throws {
        var seen: URLRequest?
        try await client("", status: 204) { seen = $0 }.deleteMeeting(id: "20261023-143000-abcdef")
        XCTAssertEqual(seen?.httpMethod, "DELETE")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/20261023-143000-abcdef")
    }

    /// A meeting that is recording or being processed answers 409; the error carries the status, so the
    /// window can say it in the user's language instead of swallowing it.
    func testDeleteOfABusyMeetingThrowsTheStatus() async {
        let c = client(#"{"error":{"message":"this meeting is still recording; finish it before deleting"}}"#, status: 409)
        do { try await c.deleteMeeting(id: "a"); XCTFail("a 409 must throw") }
        catch { XCTAssertEqual(error as? StudioError, .refused(status: 409, message: "this meeting is still recording; finish it before deleting")) }
    }

    func testDaemonSettingsAreRead() async throws {
        var seen: URLRequest?
        let s = try await client(#"{"retention_days":90}"#) { seen = $0 }.meetingDaemonSettings()
        XCTAssertEqual(seen?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/settings")
        XCTAssertEqual(s.retentionDays, 90)
        XCTAssertEqual(s.retention, .quarter)
    }

    func testDaemonSettingsWithAnUnknownPeriodAreNotGuessed() async {
        do { _ = try await client(#"{"retention_days":45}"#).meetingDaemonSettings(); XCTFail("45 days is not a choice") }
        catch { XCTAssertEqual(error as? StudioError, .badResponse) }
        do { _ = try await client("{}").meetingDaemonSettings(); XCTFail("no period is not an answer") }
        catch { XCTAssertEqual(error as? StudioError, .badResponse) }
    }
}
