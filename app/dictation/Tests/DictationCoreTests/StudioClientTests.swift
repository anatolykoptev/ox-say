import XCTest
@testable import DictationCore

final class StudioClientTests: XCTestCase {
    private func fake(status: Int = 200, body: String = "{}") -> (StudioClient, () -> URLRequest?) {
        var seen: URLRequest?
        let client = StudioClient(send: { request in
            seen = request
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        })
        return (client, { seen })
    }

    private let job = #"{"id":"j1","title":"T","status":"running","progress":{"chunks_total":2,"chunks_done":0},"outputs":{},"chunks":[]}"#

    func testStartPostsToTheProduceRoute() async throws {
        let (client, seen) = fake(status: 202, body: job)
        let started = try await client.startVoiceover(script: "Hi.", title: "T", voice: "anna", format: .long)
        XCTAssertEqual(started.id, "j1")
        XCTAssertEqual(seen()?.url?.path, "/v1/produce")
        XCTAssertEqual(seen()?.httpMethod, "POST")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertEqual(json["preset"] as? String, "youtube")
    }

    func testABusyDaemonsMessageReachesThePerson() async {
        let (client, _) = fake(status: 409, body: #"{"error":{"message":"another voiceover is running","type":"Conflict"},"running_id":"j0"}"#)
        do {
            _ = try await client.startVoiceover(script: "Hi.", title: "", voice: nil, format: .short)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StudioError, .refused(status: 409, message: "another voiceover is running"))
        }
    }

    func testStatusStopAndResumeRoutes() async throws {
        let (client, seen) = fake(body: job)
        _ = try await client.voiceover(id: "j1")
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1")
        XCTAssertEqual(seen()?.httpMethod ?? "GET", "GET")
        try await client.stopVoiceover(id: "j1")
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/cancel")
        XCTAssertEqual(seen()?.httpMethod, "POST")
        try await client.continueOnBattery(id: "j1")
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/resume")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertEqual(json["allow_battery"] as? Bool, true)
    }

    func testListReadsTheProduceRoute() async throws {
        let (client, seen) = fake(body: #"{"projects":null}"#)
        let jobs = try await client.voiceovers()
        XCTAssertEqual(jobs, [])
        XCTAssertEqual(seen()?.url?.path, "/v1/produce")
    }

    func testDesignWaitsLongEnoughForThreeTakes() async throws {
        let (client, seen) = fake(body: #"{"takes":[{"path":"/c/a.wav","duration_s":5,"suggested_name":"n-1"}]}"#)
        let takes = try await client.designVoice(description: "d", text: "t")
        XCTAssertEqual(takes.count, 1)
        XCTAssertEqual(seen()?.url?.path, "/v1/audio/voices/design")
        // 30 s start + 3 takes x 36 s + 30 s slack is what the daemon budgets itself.
        XCTAssertGreaterThan(seen()?.timeoutInterval ?? 0, 30 + 3 * 36 + 30)
    }
}
