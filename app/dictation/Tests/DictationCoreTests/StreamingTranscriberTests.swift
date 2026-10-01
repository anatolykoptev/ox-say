import XCTest
@testable import DictationCore

/// A gate a scripted response can wait behind: the test decides when the
/// daemon "answers" (e.g. to feed chunks while the session is still being created).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { cont in
            let open = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(cont)
                return false
            }
            if open { cont.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for w in pending { w.resume() }
    }
}

/// A Send that records every request and answers from a script. `maxInFlight`
/// catches pipelining: streaming must keep one request in flight at a time, so
/// an implementation that fires a chunk without waiting for the previous
/// response shows up here as 2+.
final class ScriptedSend: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let contentType: String
        let body: Data
        let timeout: TimeInterval
    }

    enum Response {
        case json(Int, String)
        case transport(Error)
        indirect case gated(Gate, Response)
    }

    private let lock = NSLock()
    private var script: [Response]
    private var requests: [Recorded] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    /// A pause inside every answer, so pipelined requests overlap in here.
    var responseDelayNanos: UInt64 = 0

    init(_ script: [Response]) { self.script = script }

    var send: TranscriptionClient.Send {
        { [self] req in
            let response = lock.withLock { () -> Response in
                requests.append(Recorded(method: req.httpMethod ?? "GET",
                                         path: req.url?.path ?? "",
                                         contentType: req.value(forHTTPHeaderField: "Content-Type") ?? "",
                                         body: req.httpBody ?? Data(),
                                         timeout: req.timeoutInterval))
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                return script.isEmpty ? .json(500, #"{"error":"unscripted request"}"#) : script.removeFirst()
            }
            defer { lock.withLock { inFlight -= 1 } }
            return try await answer(response, for: req)
        }
    }

    private func answer(_ response: Response, for req: URLRequest) async throws -> (Data, URLResponse) {
        switch response {
        case .gated(let gate, let inner):
            await gate.wait()
            return try await answer(inner, for: req)
        case .transport(let error):
            throw error
        case .json(let status, let body):
            if responseDelayNanos > 0 { try? await Task.sleep(nanoseconds: responseDelayNanos) }
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
    }

    var requestCount: Int { lock.withLock { requests.count } }

    /// Snapshot of the recorded requests, for assertions after awaits.
    func recorded() -> [Recorded] { lock.withLock { requests } }

    /// Fire-and-forget requests (a best-effort DELETE) land a little after the
    /// path that spawned them; poll rather than sleep a fixed time.
    @discardableResult
    func waitForRequests(_ n: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while requestCount < n && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return requestCount >= n
    }
}

private let sessionID = "0123456789abcdef0123456789abcdef"
private let sessionBase = "/v1/audio/transcriptions/sessions"
private let audioPath = "\(sessionBase)/\(sessionID)/audio"
private let finishPath = "\(sessionBase)/\(sessionID)/finish"
private let sessionPath = "\(sessionBase)/\(sessionID)"
private let uploadPath = "/v1/audio/transcriptions"
private let testBase = URL(string: "http://dictation.test")!

/// Each chunk's first sample carries its index, so the fake's recording proves
/// the chunks went out in order.
private func chunk(_ index: UInt32, _ count: Int = 8000) -> [Float] {
    [Float](repeating: Float(bitPattern: index + 1), count: count)
}

private func chunkIndex(_ body: Data) -> UInt32 {
    body.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
}

final class SessionClientTests: XCTestCase {
    private func client(_ fake: ScriptedSend) -> SessionClient {
        SessionClient(baseURL: testBase, send: fake.send)
    }

    // Mutation: parse "identifier" instead of "id" in SessionClient.create -> RED.
    func testCreatePostsEmptyJSONAndReturnsTheID() async throws {
        let fake = ScriptedSend([.json(200, #"{"id":"\#(sessionID)"}"#)])
        let id = try await client(fake).create()
        XCTAssertEqual(id, sessionID)
        let req = fake.recorded()[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, sessionBase)
        XCTAssertEqual(req.contentType, "application/json")
        XCTAssertEqual(String(decoding: req.body, as: UTF8.self), "{}")
        XCTAssertEqual(req.timeout, 10, accuracy: 0.01)
    }

    // Mutation: parse "texts" instead of "segments[].text" in SessionClient.audio
    // -> RED (the live text would never move).
    func testAudioPostsRawPCMAndParsesSegments() async throws {
        let fake = ScriptedSend([.json(200, #"{"segments":[{"s":0,"e":1,"text":"hello"},{"s":1,"e":2,"text":"world"}],"words":[],"pending":2}"#)])
        let reply = try await client(fake).audio(id: sessionID, pcm: Data([1, 2, 3, 4]))
        XCTAssertEqual(reply.texts, ["hello", "world"])
        XCTAssertEqual(reply.pending, 2)
        let req = fake.recorded()[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, audioPath)
        XCTAssertEqual(req.contentType, "application/octet-stream")
        XCTAssertEqual(req.body, Data([1, 2, 3, 4]))
        XCTAssertEqual(req.timeout, 10, accuracy: 0.01)
    }

    // Mutation: use the 10 s timeout for finish in SessionClient.finish -> RED
    // (the server's 60 s decode wait would be cut off by the client first).
    func testFinishWaitsLongerAndReturnsTheText() async throws {
        let fake = ScriptedSend([.json(200, #"{"text":"the whole text","done":true}"#)])
        let text = try await client(fake).finish(id: sessionID)
        XCTAssertEqual(text, "the whole text")
        let req = fake.recorded()[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, finishPath)
        XCTAssertEqual(req.contentType, "application/json")
        XCTAssertEqual(req.timeout, 90, accuracy: 0.01)
    }

    // Mutation: use POST for SessionClient.delete -> RED (the session is kept).
    func testDeleteDeletesTheSession() async throws {
        let fake = ScriptedSend([.json(200, "{}")])
        try await client(fake).delete(id: sessionID)
        let req = fake.recorded()[0]
        XCTAssertEqual(req.method, "DELETE")
        XCTAssertEqual(req.path, sessionPath)
        XCTAssertEqual(req.timeout, 10, accuracy: 0.01)
    }

    // Mutation: accept 500 as success in SessionClient.perform -> RED (the
    // caller would stream on into a dead session instead of falling back).
    func testANon200AnswerIsAnHTTPError() async {
        let fake = ScriptedSend([.json(503, #"{"error":"cooling down"}"#)])
        do {
            _ = try await client(fake).create()
            XCTFail("a non-200 must throw")
        } catch let e as TranscriptionError {
            XCTAssertEqual(e, .http(503, #"{"error":"cooling down"}"#))
        } catch { XCTFail("\(error)") }
    }

    // Mutation: swallow the thrown transport error in SessionClient.perform
    // -> RED.
    func testATransportErrorReportsTheDaemonUnreachable() async {
        let fake = ScriptedSend([.transport(URLError(.cannotConnectToHost))])
        do {
            _ = try await client(fake).create()
            XCTFail("a transport error must throw")
        } catch let e as TranscriptionError {
            guard case .daemonUnreachable = e else { return XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }
}

final class StreamingTranscriberTests: XCTestCase {
    private func transcriber(_ fake: ScriptedSend) -> StreamingTranscriber {
        StreamingTranscriber(baseURL: testBase, send: fake.send)
    }

    // Mutation: in the pump, fire each chunk in its own `Task {}` instead of
    // awaiting the previous response -> RED via maxInFlight (chunks overlap).
    @MainActor
    func testChunksGoOutInOrderOneAtATimeThenFinish() async throws {
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[{"s":0,"e":1,"text":"hello"}],"pending":1}"#),
            .json(200, #"{"segments":[{"s":1,"e":2,"text":" world"}],"pending":0}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .json(200, #"{"text":"  hello world.  ","done":true}"#),
        ])
        fake.responseDelayNanos = 30_000_000
        let st = transcriber(fake)
        var texts: [String] = []
        st.onText = { texts.append($0) }
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        await st.feed(chunk(1) + chunk(2, 3000), generation: st.feedGeneration)
        let all = chunk(0) + chunk(1) + chunk(2, 3000)
        let text = try await st.finish(all: all)
        XCTAssertEqual(text, "hello world.", "finish's text wins, trimmed")

        let arrived = await fake.waitForRequests(5)
        XCTAssertTrue(arrived)
        let reqs = fake.recorded()
        XCTAssertEqual(reqs.map(\.path),
                       [sessionBase, audioPath, audioPath, audioPath, finishPath])
        XCTAssertEqual(reqs[1].contentType, "application/octet-stream")
        XCTAssertEqual(reqs[1].body.count, 32000, "8000 float32 samples")
        XCTAssertEqual(reqs[2].body.count, 32000)
        XCTAssertEqual(reqs[3].body.count, 12000, "the remaining partial chunk")
        XCTAssertEqual(chunkIndex(reqs[1].body), 1)
        XCTAssertEqual(chunkIndex(reqs[2].body), 2)
        XCTAssertEqual(chunkIndex(reqs[3].body), 3)
        XCTAssertEqual(fake.maxInFlight, 1, "one request in flight at a time")
        XCTAssertEqual(texts, ["hello", "hello world", "hello world"],
                       "committed text grows with single spaces, trimmed; a 200 with no new segments re-emits")
    }

    // Mutation: StreamingTranscriber.finish returns "" instead of falling back
    // to the one-shot upload -> RED (the dictation would paste nothing).
    @MainActor
    func testCreate404FallsBackToOneShot() async throws {
        try await assertCreateFailureFallsBack(.json(404, #"{"error":"no such route"}"#))
    }

    @MainActor
    func testCreate501FallsBackToOneShot() async throws {
        try await assertCreateFailureFallsBack(.json(501, #"{"error":"no VAD model"}"#))
    }

    @MainActor
    func testCreate503FallsBackToOneShot() async throws {
        try await assertCreateFailureFallsBack(.json(503, #"{"error":"cooling down"}"#))
    }

    @MainActor
    func testCreateTransportErrorFallsBackToOneShot() async throws {
        try await assertCreateFailureFallsBack(.transport(URLError(.cannotConnectToHost)))
    }

    private func assertCreateFailureFallsBack(_ response: ScriptedSend.Response) async throws {
        let fake = ScriptedSend([response, .json(200, #"{"text":"uploaded"}"#)])
        let st = transcriber(fake)
        st.begin()
        let all = chunk(0, 19000)
        await st.feed(all, generation: st.feedGeneration)
        let text = try await st.finish(all: all)
        XCTAssertEqual(text, "uploaded")
        let arrived = await fake.waitForRequests(2)
        XCTAssertTrue(arrived)
        let reqs = fake.recorded()
        XCTAssertEqual(reqs.map(\.path), [sessionBase, uploadPath],
                       "no audio or finish request once create failed")
        let wavBytes = 44 + all.count * 2
        XCTAssertGreaterThanOrEqual(reqs[1].body.count, wavBytes, "the one-shot upload carries ALL samples")
        XCTAssertLessThan(reqs[1].body.count, wavBytes + 1000)
    }

    // Mutation: keep streaming after an audio 500 (drop the fallback flag)
    // -> RED: finish is called and no one-shot upload happens.
    @MainActor
    func testAnAudio500StopsStreamingAndFallsBack() async throws {
        // The fallback DELETE and the one-shot upload race; either order works.
        try await assertAudioFailureFallsBack(
            [.json(500, #"{"error":"decode failed"}"#),
             .json(200, #"{"text":"uploaded"}"#), .json(200, #"{"text":"uploaded"}"#)],
            audioAnswersBeforeFailure: 0)
    }

    @MainActor
    func testAnAudio429StopsStreamingAndFallsBack() async throws {
        try await assertAudioFailureFallsBack(
            [.json(200, #"{"segments":[{"s":0,"e":1,"text":"hi"}],"pending":0}"#),
             .json(429, #"{"error":"too busy"}"#),
             .json(200, #"{"text":"uploaded"}"#), .json(200, #"{"text":"uploaded"}"#)],
            audioAnswersBeforeFailure: 1)
    }

    private func assertAudioFailureFallsBack(_ afterCreate: [ScriptedSend.Response],
                                             audioAnswersBeforeFailure: Int) async throws {
        let fake = ScriptedSend([.json(200, #"{"id":"\#(sessionID)"}"#)] + afterCreate)
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        await st.feed(chunk(1), generation: st.feedGeneration)
        await st.feed(chunk(2), generation: st.feedGeneration)
        let all = chunk(0) + chunk(1) + chunk(2)
        let text = try await st.finish(all: all)
        XCTAssertEqual(text, "uploaded")
        // create + failing audio + DELETE + upload (earlier audio successes too)
        let arrived = await fake.waitForRequests(4 + audioAnswersBeforeFailure)
        XCTAssertTrue(arrived)
        let reqs = fake.recorded()
        XCTAssertEqual(reqs.filter { $0.path == audioPath }.count, audioAnswersBeforeFailure + 1,
                       "streaming stops at the first failure")
        XCTAssertTrue(reqs.contains { $0.method == "DELETE" && $0.path == sessionPath },
                      "a failed session gets a best-effort DELETE")
        XCTAssertFalse(reqs.contains { $0.path == finishPath }, "finish is never POSTed after a failure")
        let upload = reqs.first { $0.path == uploadPath }
        XCTAssertNotNil(upload)
        XCTAssertGreaterThanOrEqual(upload!.body.count, 44 + all.count * 2,
                                    "the one-shot upload carries ALL samples")
    }

    // Mutation: keep going when finish answers non-200 -> RED: the session's
    // finish error is swallowed and no upload happens.
    @MainActor
    func testAFinish500FallsBack() async throws {
        try await assertFinishFailureFallsBack(.json(500, #"{"error":"decode failed"}"#))
    }

    @MainActor
    func testAFinish504FallsBack() async throws {
        try await assertFinishFailureFallsBack(.json(504, #"{"error":"finish waited too long"}"#))
    }

    private func assertFinishFailureFallsBack(_ finishResponse: ScriptedSend.Response) async throws {
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[{"s":0,"e":1,"text":"hi"}],"pending":0}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            finishResponse,
            // The fallback DELETE and the one-shot upload race; both carry text.
            .json(200, #"{"text":"uploaded"}"#),
            .json(200, #"{"text":"uploaded"}"#),
        ])
        let st = transcriber(fake)
        st.begin()
        let all = chunk(0, 9000)
        await st.feed(all, generation: st.feedGeneration)
        let text = try await st.finish(all: all)
        XCTAssertEqual(text, "uploaded")
        let arrived = await fake.waitForRequests(6)
        XCTAssertTrue(arrived)
        XCTAssertTrue(fake.recorded().contains { $0.path == uploadPath })
        XCTAssertTrue(fake.recorded().contains { $0.path == finishPath })
        XCTAssertTrue(fake.recorded().contains { $0.method == "DELETE" && $0.path == sessionPath },
                      "a failed session gets a best-effort DELETE")
    }

    // Mutation: skip the DELETE in StreamingTranscriber.cancel -> RED (the
    // session stays open on the daemon until it times out).
    @MainActor
    func testCancelDuringRecordingDeletesAndStopsEverything() async throws {
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[{"s":0,"e":1,"text":"hi"}],"pending":0}"#),
            .json(200, "{}"),
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        let arrived = await fake.waitForRequests(2)
        XCTAssertTrue(arrived, "create + first audio")
        st.cancel()
        let deleted = await fake.waitForRequests(3)
        XCTAssertTrue(deleted, "the session must be deleted")
        XCTAssertEqual(fake.recorded().last?.method, "DELETE")
        XCTAssertEqual(fake.recorded().last?.path, sessionPath)
        await st.feed(chunk(1), generation: st.feedGeneration) // after cancel a feed is dropped
        // Mutation: drop `!cancelled` from the guard in feed -> RED (the dead
        // dictation keeps buffering what the recorder still delivers).
        XCTAssertEqual(st.acceptedCount, chunk(0).count, "a feed after cancel must not be accepted")
        // A pump kicked by that feed would set `sending` under feed's own
        // lock, so once none runs the recorded requests are final.
        let deadline = Date().addingTimeInterval(2)
        while st.pumpSending && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(st.pumpSending, "the post-cancel feed must not start a pump")
        XCTAssertEqual(fake.requestCount, 3, "cancel + buffered feed sends nothing else")
        XCTAssertFalse(fake.recorded().contains { $0.path == finishPath })
        XCTAssertFalse(fake.recorded().contains { $0.path == uploadPath })
    }

    // Mutation: drop the late-id DELETE in the create watcher -> RED (a session
    // created after Esc would be left open on the daemon).
    @MainActor
    func testCancelWhileCreateIsInFlightDeletesTheLateSession() async throws {
        let gate = Gate()
        let fake = ScriptedSend([.gated(gate, .json(200, #"{"id":"\#(sessionID)"}"#)), .json(200, "{}")])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        st.cancel()
        gate.open()
        let arrived = await fake.waitForRequests(2)
        XCTAssertTrue(arrived, "the late session must be deleted")
        XCTAssertEqual(fake.recorded().last?.method, "DELETE")
        XCTAssertEqual(fake.recorded().last?.path, sessionPath)
    }

    // Mutation: send the buffered chunks in reverse order when the id arrives
    // -> RED via the body-order assertions.
    @MainActor
    func testChunksFedBeforeTheIDAreSentFirstInOrder() async throws {
        let gate = Gate()
        let fake = ScriptedSend([
            .gated(gate, .json(200, #"{"id":"\#(sessionID)"}"#)),
            .json(200, #"{"segments":[{"s":0,"e":1,"text":"early"}],"pending":0}"#),
            .json(200, #"{"segments":[{"s":1,"e":2,"text":"bird"}],"pending":0}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .json(200, #"{"text":"early bird","done":true}"#),
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        await st.feed(chunk(1), generation: st.feedGeneration)
        await st.feed(chunk(2, 100), generation: st.feedGeneration)
        gate.open()
        let text = try await st.finish(all: chunk(0) + chunk(1) + chunk(2, 100))
        XCTAssertEqual(text, "early bird")
        let arrived = await fake.waitForRequests(5)
        XCTAssertTrue(arrived)
        let audio = fake.recorded().filter { $0.path == audioPath }
        XCTAssertEqual(audio.map { chunkIndex($0.body) }, [1, 2, 3],
                       "buffered chunks go out first, in order")
    }

    /// Polls until a request matching path (and method) is recorded.
    private func waitFor(_ fake: ScriptedSend, path: String, method: String? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        func found() -> Bool {
            fake.recorded().contains { $0.path == path && (method == nil || $0.method == method) }
        }
        while !found() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return found()
    }

    // Mutation: in the pump's exit branch, resume the waiters with this
    // pump's stale-generation verdict (`generation == g && …`) before kicking
    // a successor pump -> RED: B's waiter resolves false and finish uploads.
    @MainActor
    func testAStalePumpDoesNotResolveTheNextDictationsDrain() async throws {
        let gate = Gate()
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),                        // A create
            .gated(gate, .json(200, #"{"segments":[],"pending":0}"#)),     // A audio, held
            .json(200, #"{"id":"\#(sessionID)"}"#),   // A DELETE and B create race;
            .json(200, #"{"id":"\#(sessionID)"}"#),   // either order answers both.
            .json(200, #"{"segments":[],"pending":0}"#),                   // B audio
            .json(200, #"{"text":"b text","done":true}"#),                 // B finish
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        var arrived = await fake.waitForRequests(2)
        XCTAssertTrue(arrived, "A's create and held audio")
        st.cancel()
        st.begin()
        arrived = await fake.waitForRequests(4)
        XCTAssertTrue(arrived, "A's delete and B's create")
        await st.feed(chunk(7), generation: st.feedGeneration) // buffers: A's pump still owns `sending`
        let finish = Task { try await st.finish(all: chunk(7)) }
        // B's drain waiter must be queued before A's pump gets to exit.
        let deadline = Date().addingTimeInterval(2)
        while st.pendingDrainWaiters == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(st.pendingDrainWaiters, 1)
        gate.open()
        let text = try await finish.value
        XCTAssertEqual(text, "b text")
        arrived = await fake.waitForRequests(6)
        XCTAssertTrue(arrived)
        let reqs = fake.recorded()
        XCTAssertEqual(reqs.filter { $0.path == audioPath }.count, 2,
                       "B's chunk streams through B's session")
        XCTAssertEqual(reqs.last?.path, finishPath)
        XCTAssertFalse(reqs.contains { $0.path == uploadPath },
                       "B must not fall back to a one-shot upload")
    }

    // Mutation: drop the cancelled/generation re-check before the one-shot
    // upload in finish -> RED: the cancelled dictation uploads anyway.
    @MainActor
    func testEscDuringAnInFlightFinishNeverUploads() async throws {
        let gate = Gate()
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .gated(gate, .json(500, #"{"error":"finish blew up"}"#)),
            .json(200, "{}"), // the cancel DELETE
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        let finish = Task { try await st.finish(all: chunk(0)) }
        let inFlight = await fake.waitForRequests(3)
        XCTAssertTrue(inFlight, "the finish POST is in flight")
        st.cancel()
        gate.open()
        do {
            _ = try await finish.value
            XCTFail("a cancelled finish must throw CancellationError")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        let deleted = await fake.waitForRequests(4)
        XCTAssertTrue(deleted)
        let reqs = fake.recorded()
        XCTAssertEqual(reqs.last?.method, "DELETE")
        XCTAssertFalse(reqs.contains { $0.path == uploadPath },
                       "no one-shot upload after Esc")
    }

    // Mutation: skip the `all[accepted...]` suffix append in finish -> RED:
    // the tail still in the feed stream never reaches the session. Also
    // covers the drop: a chunk fed while finish is in flight must not be
    // sent (drop the `guard !finishing` in feed -> RED via the count).
    @MainActor
    func testFinishFlushesSamplesStillInTheFeedStream() async throws {
        let gate = Gate()
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .gated(gate, .json(200, #"{"text":"with tail","done":true}"#)),
        ])
        let st = transcriber(fake)
        st.begin()
        // The AsyncStream consumer lags: the tail was recorded but not fed.
        await st.feed(chunk(0), generation: st.feedGeneration)
        let all = chunk(0) + chunk(1, 3000)
        let finish = Task { try await st.finish(all: all) }
        let sent = await fake.waitForRequests(4)
        XCTAssertTrue(sent, "create + both audio chunks + held finish POST")
        // Fed while finish is in flight: dropped, never sent.
        await st.feed(chunk(9), generation: st.feedGeneration)
        let deadline = Date().addingTimeInterval(2)
        while st.pumpSending && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(st.pumpSending)
        XCTAssertEqual(fake.requestCount, 4, "a mid-finish feed is not sent")
        gate.open()
        let text = try await finish.value
        XCTAssertEqual(text, "with tail")
        let audio = fake.recorded().filter { $0.path == audioPath }
        XCTAssertEqual(audio.count, 2, "the unfed tail must reach the session")
        XCTAssertEqual(audio[1].body.count, 12000, "the withheld 3000 samples")
        XCTAssertEqual(chunkIndex(audio[1].body), 2)
        XCTAssertEqual(fake.recorded().last?.path, finishPath)
        XCTAssertFalse(fake.recorded().contains { $0.path == uploadPath })
    }

    // Mutation: drop the `accepted > all.count` fallback in finish -> RED:
    // the polluted session is finished instead of re-uploaded whole.
    @MainActor
    func testOverFedSamplesFallBackToTheUpload() async throws {
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            // The fallback DELETE and the one-shot upload race; both carry text.
            .json(200, #"{"text":"uploaded"}"#),
            .json(200, #"{"text":"uploaded"}"#),
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        await st.feed(chunk(9), generation: st.feedGeneration) // foreign: more fed than the recording holds
        let text = try await st.finish(all: chunk(0))
        XCTAssertEqual(text, "uploaded")
        let uploaded = await waitFor(fake, path: uploadPath)
        XCTAssertTrue(uploaded, "the whole recording is uploaded")
        let deleted = await waitFor(fake, path: sessionPath, method: "DELETE")
        XCTAssertTrue(deleted, "the polluted session gets a best-effort DELETE")
        XCTAssertFalse(fake.recorded().contains { $0.path == finishPath },
                       "a session holding foreign audio is never finished")
    }

    // Mutation: keep `id` after a successful finish -> RED: the next begin()
    // DELETEs the already-finished session (guaranteed 404).
    @MainActor
    func testABeginAfterASuccessfulFinishSendsNoDelete() async throws {
        let fake = ScriptedSend([
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
            .json(200, #"{"text":"done","done":true}"#),
            .json(200, #"{"id":"\#(sessionID)"}"#),
            .json(200, #"{"segments":[],"pending":0}"#),
        ])
        let st = transcriber(fake)
        st.begin()
        await st.feed(chunk(0), generation: st.feedGeneration)
        let text = try await st.finish(all: chunk(0))
        XCTAssertEqual(text, "done")
        st.begin()
        await st.feed(chunk(1), generation: st.feedGeneration)
        let arrived = await fake.waitForRequests(5)
        XCTAssertTrue(arrived, "second create + audio")
        XCTAssertFalse(fake.recorded().contains { $0.method == "DELETE" },
                       "a finished session is forgotten, not deleted")
    }

    /// One body that answers create, audio, finish and DELETE alike, so the
    /// cancel-DELETE / next-create race can consume script entries in any order.
    private static let universalReply =
        #"{"id":"\#(sessionID)","segments":[],"pending":0,"text":"b","done":true}"#

    // Mutation: drop `g == generation` from the guard in feed -> RED: the stale
    // chunk is POSTed into B's session (audio.count grows to 3, and the body at
    // index 1 is A's chunk).
    @MainActor
    func testAChunkFromADeadDictationNeverReachesTheNextSession() async throws {
        let fake = ScriptedSend([.json(200, #"{"id":"\#(sessionID)"}"#),
                               .json(200, #"{"segments":[],"pending":0}"#)]
                              + [ScriptedSend.Response](repeating: .json(200, Self.universalReply), count: 5))
        let st = transcriber(fake)
        st.begin()
        let genA = st.feedGeneration
        await st.feed(chunk(0), generation: genA)
        var arrived = await fake.waitForRequests(2)
        XCTAssertTrue(arrived, "A's create and audio")
        st.cancel()
        st.begin()
        let genB = st.feedGeneration
        XCTAssertNotEqual(genA, genB)
        // A chunk of A landing now — still queued in a dead stream, or a feed
        // suspended across begin() — must be dropped, never fed into B.
        await st.feed(chunk(9), generation: genA)
        await st.feed(chunk(1), generation: genB)
        let text = try await st.finish(all: chunk(1))
        XCTAssertEqual(text, "b")
        arrived = await fake.waitForRequests(6)
        XCTAssertTrue(arrived)
        let audio = fake.recorded().filter { $0.path == audioPath }
        XCTAssertEqual(audio.count, 2, "one audio POST per dictation")
        XCTAssertEqual(audio[0].body.count, 32000)
        XCTAssertEqual(chunkIndex(audio[0].body), 1, "A's chunk went to A's session")
        XCTAssertEqual(audio[1].body.count, 32000)
        XCTAssertEqual(chunkIndex(audio[1].body), 2, "B's session holds only B's chunk")
        XCTAssertFalse(fake.recorded().contains { $0.path == uploadPath })
    }

    // The app's real wiring: a consumer suspended inside `for await` wakes to a
    // chunk that landed after the next begin() — the stale tag must drop it.
    // Awaiting the finished stream's consumer joins every feed it ran, so no
    // sleep is needed to know the stale feed happened.
    @MainActor
    func testAChunkQueuedInAFinishedStreamIsDroppedAfterBegin() async throws {
        let fake = ScriptedSend([ScriptedSend.Response](repeating: .json(200, Self.universalReply), count: 7))
        let st = transcriber(fake)
        st.begin()
        let genA = st.feedGeneration
        let (chunks, yielder) = AsyncStream<[Float]>.makeStream()
        let consumer = Task { for await c in chunks { await st.feed(c, generation: genA) } }
        st.cancel()
        st.begin()
        let genB = st.feedGeneration
        yielder.yield(chunk(9))   // A's stream still held this past begin()
        yielder.finish()
        await consumer.value      // every queued element was fed by now
        await st.feed(chunk(1), generation: genB)
        let text = try await st.finish(all: chunk(1))
        XCTAssertEqual(text, "b")
        // A's create, A's DELETE (the id arrives cancelled, the watcher drops
        // it), B's create, B's audio, B's finish — in whichever order the two
        // racing writes land; only the audio POST carries samples.
        let arrived = await fake.waitForRequests(5)
        XCTAssertTrue(arrived)
        let audio = fake.recorded().filter { $0.path == audioPath }
        XCTAssertEqual(audio.count, 1, "B's session gets exactly its own chunk")
        XCTAssertEqual(audio[0].body.count, 32000)
        XCTAssertEqual(chunkIndex(audio[0].body), 2)
        XCTAssertFalse(fake.recorded().contains { $0.path == uploadPath })
    }
}

final class TranscriberControllerTests: XCTestCase {
    final class FakeTranscriber: Transcriber {
        var began = 0
        var cancelled = 0
        var finishCalls: [[Float]] = []
        var result: String = "text"
        var finishDelayNanos: UInt64 = 0
        func begin() { began += 1 }
        var feedGeneration: Int { began }
        func feed(_ samples: [Float], generation _: Int) async {}
        func finish(all: [Float]) async throws -> String {
            finishCalls.append(all)
            if finishDelayNanos > 0 { try? await Task.sleep(nanoseconds: finishDelayNanos) }
            return result
        }
        func cancel() { cancelled += 1 }
    }

    @MainActor func run(_ c: DictationController, until state: DictationState, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.state, state, file: file, line: line)
    }

    // Mutation: drop `transcriber.begin()` in keyDown -> RED (no session is
    // opened, so streaming never starts).
    @MainActor
    func testBeginOnStartAndFinishOnStop() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: out, mode: .hold, transcriber: t)
        c.keyDown()
        XCTAssertEqual(t.began, 1)
        c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(t.finishCalls, [rec.samples])
        XCTAssertEqual(out.delivered, ["text"])
    }

    // Mutation: drop `transcriber.cancel()` in the .recording branch of cancel
    // -> RED (the session leaks until the daemon reaps it).
    @MainActor
    func testCancelWhileRecordingCancelsTheTranscriber() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        c.keyDown()
        c.cancel()
        XCTAssertEqual(t.cancelled, 1)
        XCTAssertTrue(t.finishCalls.isEmpty)
    }

    // Mutation: drop `transcriber.cancel()` in the .transcribing branch of
    // cancel -> RED (a session stays open and its late text is still awaited).
    @MainActor
    func testCancelWhileTranscribingCancelsTheTranscriber() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let t = FakeTranscriber()
        t.finishDelayNanos = 300_000_000
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        c.keyDown(); c.keyUp()
        XCTAssertEqual(c.state, .transcribing)
        c.cancel()
        XCTAssertEqual(t.cancelled, 1)
        await run(c, until: .idle)
    }

    // Mutation: drop `transcriber.cancel()` in the minSeconds guard of finish
    // -> RED (a key tap would leave a session open on the daemon).
    @MainActor
    func testAShortTapCancelsTheTranscriber() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0, count: 1600) // 0.1 s
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(t.cancelled, 1)
        XCTAssertTrue(t.finishCalls.isEmpty)
    }

    // Mutation: in DictationController.keyDown, move `try recorder.start()`
    // above `openRoute()` / `state = .recording` -> RED. A chunk recorded
    // before the route exists is in the recording but never in the session.
    @MainActor
    func testTheRouteExistsBeforeTheMicrophoneStarts() {
        let rec = FakeRecorder()
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        var stateAtStart: DictationState?
        var routedAtStart = false
        var beganAtStart = 0
        rec.onStart = { stateAtStart = c.state; routedAtStart = rec.onSamples != nil; beganAtStart = t.began }
        c.keyDown()
        XCTAssertTrue(routedAtStart, "the chunk route must exist before the first chunk")
        XCTAssertEqual(beganAtStart, 1, "the generation must be minted before the first chunk")
        XCTAssertEqual(stateAtStart, .recording)
    }

    // Mutation: move `try recorder.prepare()` below `transcriber.begin()` in
    // keyDown -> RED (a press without microphone permission would open a
    // daemon session, which cold-starts the speech-to-text server).
    @MainActor
    func testAPressThatCannotRecordOpensNoSession() {
        struct NoPermission: LocalizedError { var errorDescription: String? { "no permission" } }
        let rec = FakeRecorder(); rec.prepareError = NoPermission()
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        var states: [DictationState] = []
        var errors: [String] = []
        c.onState = { states.append($0) }
        c.onError = { errors.append($0) }
        c.keyDown()
        XCTAssertEqual(t.began, 0, "no session for a press that cannot record")
        XCTAssertEqual(rec.started, 0)
        XCTAssertNil(rec.onSamples)
        XCTAssertEqual(states, [])
        XCTAssertEqual(errors, ["Could not start recording: no permission"])
    }

    // Mutation: drop `transcriber.cancel()` (or `closeRoute()`) in keyDown's
    // catch -> RED (the session opened by begin() would stay open on the
    // daemon, or the recorder would keep a dead route).
    @MainActor
    func testAFailedStartCancelsTheSessionAndReturnsToIdle() {
        struct EngineFailed: LocalizedError { var errorDescription: String? { "engine failed" } }
        let rec = FakeRecorder(); rec.startError = EngineFailed()
        let t = FakeTranscriber()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        var states: [DictationState] = []
        var errors: [String] = []
        c.onState = { states.append($0) }
        c.onError = { errors.append($0) }
        c.keyDown()
        XCTAssertEqual(t.began, 1)
        XCTAssertEqual(t.cancelled, 1)
        XCTAssertNil(rec.onSamples, "the route is closed")
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(states, [.recording, .idle])
        XCTAssertEqual(errors, ["Could not start recording: engine failed"])
        rec.startError = nil
        c.keyDown()
        XCTAssertEqual(c.state, .recording, "a failed start must not wedge the next press")
    }

    // Mutation: drop `recorder.onSamples = route.sink` in openRoute -> RED
    // (nothing streams; every dictation silently becomes a full upload).
    // Mutation: drop `closeRoute()` in finish or in cancel -> RED (the
    // recorder keeps feeding a dead dictation's route).
    @MainActor
    func testRecorderChunksReachTheTranscriberUntilTheDictationEnds() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let t = FeedRouteTests.FeedLog()
        t.generation = 7
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold, transcriber: t)
        c.keyDown()
        rec.onSamples?([1])
        let deadline = Date().addingTimeInterval(5)
        while t.fed.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(t.fed.map(\.0), [[1]], "a recorder chunk must reach feed")
        XCTAssertEqual(t.fed.map(\.1), [7], "tagged with the dictation's generation")
        c.keyUp()
        XCTAssertNil(rec.onSamples, "finish closes the route")
        await run(c, until: .idle)

        c.keyDown()
        XCTAssertNotNil(rec.onSamples)
        c.cancel()
        XCTAssertNil(rec.onSamples, "cancel closes the route")
    }
}
