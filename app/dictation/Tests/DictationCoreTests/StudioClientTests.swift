import XCTest
@testable import DictationCore

final class StudioClientTests: XCTestCase {
    private func fake(status: Int = 200, body: String = "{}") -> (StudioClient, () -> URLRequest?) {
        studioClientFake(status: status, body: body)
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

    /// The bulk route reads every chunk detail in one request; the timeout is
    /// the quick read's, and a shorter one must fail this test.
    func testChunksReadsTheBulkRoute() async throws {
        let (client, seen) = fake(body: #"{"chunks":[{"index":1,"paragraph":0,"status":"pending","text":"Привет."}]}"#)
        let chunks = try await client.chunks(id: "j1")
        XCTAssertEqual(chunks, [ProduceChunkDetail(index: 1, paragraph: 0, text: "Привет.", status: .pending)])
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/chunks")
        XCTAssertEqual(seen()?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(seen()?.timeoutInterval, StudioClient.quickTimeout)
    }

    /// The daemon's own bulk shape (chunksDetail marshals a chunkDetailOut per
    /// chunk): the optional knobs ride their omitempty rules, a takes list may
    /// read null, and take_files is a key->path map.
    func testBulkChunksDecodeTheDaemonShape() {
        let body = Data(#"{"chunks":[{"index":0,"paragraph":0,"text":"Привет!","style":"радостно","pause_after_s":0.4,"pace":1.1,"status":"ok","pick":"a1","takes":[{"key":"a1"},{"key":"b2"}],"take_files":{"a1":"/p/a1.wav","b2":"/p/b2.wav"}},{"index":1,"paragraph":1,"text":"Два.","status":"pending","takes":null,"take_files":null}]}"#.utf8)
        let list = StudioClient.decodeChunks(body)!
        XCTAssertEqual(list[0].pace, 1.1)
        XCTAssertEqual(list[0].pauseAfter, 0.4)
        XCTAssertEqual(list[0].takeKeys, ["a1", "b2"])
        XCTAssertEqual(list[0].style, "радостно")
        XCTAssertEqual(list[0].pick, "a1")
        XCTAssertEqual(list[0].takeFiles["b2"], "/p/b2.wav")
        XCTAssertEqual(list[1].takeKeys, [], "a null takes list is no takes, not a dropped chunk")
        XCTAssertEqual(list[1].takeFiles, [:])
        XCTAssertEqual(list[1].pace, 0, "absent pace is neutral")
        XCTAssertNil(list[1].pick)
        XCTAssertEqual(StudioClient.decodeChunks(Data(#"{"chunks":null}"#.utf8)), [])
        XCTAssertNil(StudioClient.decodeChunks(Data("nope".utf8)))
    }

    /// A delivery writes `pause_after` (the read is `pause_after_s`) and sends
    /// `loudness_lufs` only when it changed — an older daemon's strict decoder
    /// answers 400 to a key it does not know.
    func testDeliverAndEditWriteTheDaemonKeys() async throws {
        let (client, seen) = fake(body: #"{"id":"j1","status":"running"}"#)
        try await client.deliver(id: "j1", entries: [DeliveryEntry(n: 3, style: "тепло", pauseAfter: 0.4, pace: 1.1)], loudness: -16)
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/delivery")
        XCTAssertEqual(seen()?.timeoutInterval, StudioClient.startTimeout)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        let entry = try XCTUnwrap((json["chunks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["n"] as? Int, 3)
        XCTAssertEqual(entry["pause_after"] as? Double, 0.4, "the WRITE key is pause_after; the read key is pause_after_s")
        XCTAssertEqual(entry["pace"] as? Double, 1.1)
        XCTAssertEqual(entry["style"] as? String, "тепло")
        XCTAssertEqual(json["loudness_lufs"] as? Double, -16)

        try await client.editText(id: "j1", chunk: 1, text: "Новый текст.")
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/chunks/1")
        XCTAssertEqual(seen()?.timeoutInterval, StudioClient.startTimeout)
        let edit = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertEqual(edit["action"] as? String, "edit")
        XCTAssertEqual(edit["text"] as? String, "Новый текст.")
    }

    /// An untouched knob is absent from the body: a delivery entry sends only
    /// `n` plus the fields the person changed, and `loudness_lufs` is left out
    /// of a loudness-untouched batch entirely.
    func testDeliverySendsOnlyTheChangedKeys() async throws {
        let (client, seen) = fake(body: #"{"id":"j1","status":"done"}"#)
        try await client.deliver(id: "j1", entries: [DeliveryEntry(n: 0, pauseAfter: 2), DeliveryEntry(n: 2)], loudness: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertNil(json["loudness_lufs"], "no loudness change: the key must not go out")
        let chunks = try XCTUnwrap(json["chunks"] as? [[String: Any]])
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Set(chunks[0].keys), ["n", "pause_after"], "only the changed knob is sent")
        XCTAssertEqual(Set(chunks[1].keys), ["n"])
    }

    /// Regenerate and pick post their action to the chunk's own route; the
    /// mutation `"pick" -> "choose"` must go red here.
    func testRegenerateAndPickPostTheChunkAction() async throws {
        let (client, seen) = fake(body: #"{"id":"j1","status":"running"}"#)
        try await client.regenerate(id: "j1", chunk: 2, takes: 2)
        XCTAssertEqual(seen()?.url?.path, "/v1/produce/j1/chunks/2")
        XCTAssertEqual(seen()?.httpMethod, "POST")
        XCTAssertEqual(seen()?.timeoutInterval, StudioClient.startTimeout)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "regenerate")
        XCTAssertEqual(json["takes"] as? Int, 2)
        try await client.pick(id: "j1", chunk: 2, take: "b2")
        XCTAssertEqual(seen()?.timeoutInterval, StudioClient.startTimeout)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen()?.httpBody)) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "pick")
        XCTAssertEqual(json["take"] as? String, "b2")
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
