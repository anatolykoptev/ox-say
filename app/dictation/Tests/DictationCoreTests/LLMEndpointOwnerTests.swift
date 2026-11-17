import Foundation
import XCTest
@testable import DictationCore

/// The model-access section's credentials: the key is never in the settings answer, it and turning the endpoint on
/// travel with the owner token, an older daemon leaves the toggle disabled, and "New key" taps cannot show a stale key.
final class LLMEndpointOwnerTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    private func client(_ answer: String = "{}", status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: the settings answer

    /// An answer without the endpoint fields (an older daemon) is not "endpoint off": the toggle stays disabled.
    /// Mutation: MeetingDaemonSettings.decode, `llmEndpointAnswered: true` -> RED.
    func testAnOlderDaemonsAnswerLeavesTheToggleUnverified() {
        let old = MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":true}"#.utf8))
        XCTAssertNotNil(old)
        XCTAssertEqual(old?.llmEndpointAnswered, false)
        XCTAssertFalse(LLMEndpointValues.of(old).verified)
        XCTAssertFalse(LLMEndpointValues.of(nil).verified)
        let new = MeetingDaemonSettings.decode(Data(
            #"{"retention_days":30,"llm_endpoint":"on","llm_endpoint_url":"http://127.0.0.1:8094/v1","llm_endpoint_ctx":131072,"llm_endpoint_ctx_effective":65536}"#.utf8))
        let v = LLMEndpointValues.of(new)
        XCTAssertTrue(v.verified)
        XCTAssertTrue(v.on)
        XCTAssertEqual(v.url, "http://127.0.0.1:8094/v1")
        XCTAssertEqual(v.contextTokens, 65536, "what the model runs with")
        XCTAssertEqual(v.askedTokens, 131072, "what the settings ask")
        XCTAssertEqual(v.key, "", "the settings answer carries no key")
        // A key a (hostile or older) daemon still put in the answer is not taken from it.
        let leaked = MeetingDaemonSettings.decode(Data(
            #"{"retention_days":30,"llm_endpoint":"on","llm_endpoint_url":"u","llm_endpoint_key":"deadbeef"}"#.utf8))
        XCTAssertEqual(LLMEndpointValues.of(leaked).key, "")
    }

    func testTheContextLineSaysWhenLessThanAskedIsInUse() {
        let same = LLMEndpointValues(contextTokens: 131072, askedTokens: 131072, verified: true)
        XCTAssertEqual(same.contextLine(text: { $0.rawValue }), String(format: "settings.llm_endpoint.ctx", 131072))
        let less = LLMEndpointValues(contextTokens: 65536, askedTokens: 131072, verified: true)
        XCTAssertEqual(less.contextLine(text: { $0.rawValue }), String(format: "settings.llm_endpoint.ctx_asked", 65536, 131072))
    }

    // MARK: owner calls

    /// Turning the endpoint on carries the owner bearer; without a token nothing is sent at all.
    /// Mutation: MeetingClient.setLLMEndpoint, drop the Authorization header -> RED.
    func testTurningItOnSendsTheOwnerBearer() async throws {
        var seen: URLRequest?
        try await client(record: { seen = $0 }).setLLMEndpoint(on: true, ownerToken: token)
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["llm_endpoint"] as? String, "on")

        seen = nil
        do {
            try await client(record: { seen = $0 }).setLLMEndpoint(on: true, ownerToken: nil)
            XCTFail("turning it on without the owner token must not be tried")
        } catch { XCTAssertEqual(error as? LLMEndpointOwnerError, .tokenMissing) }
        XCTAssertNil(seen, "nothing was sent")

        // Off needs nobody: it is sent even when the token cannot be read.
        try await client(record: { seen = $0 }).setLLMEndpoint(on: false, ownerToken: nil)
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnUnacceptedOwnerTokenIsNamed() async {
        do {
            try await client(status: 401).setLLMEndpoint(on: true, ownerToken: token)
            XCTFail("a 401 is a refusal")
        } catch { XCTAssertEqual(error as? LLMEndpointOwnerError, .denied) }
    }

    func testTheKeyAndItsRotationNeedTheOwnerBearer() async throws {
        var seen: [URLRequest] = []
        let c = client(#"{"llm_endpoint_key":"k1"}"#, record: { seen.append($0) })
        let key = try await c.llmEndpointKey(ownerToken: token)
        let fresh = try await c.regenerateLLMEndpointKey(ownerToken: token)
        XCTAssertEqual([key, fresh], ["k1", "k1"])
        XCTAssertEqual(seen.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(seen.map { $0.url?.path }, ["/v1/meetings/llm-endpoint/key", "/v1/meetings/llm-endpoint/key"])
        XCTAssertEqual(seen.compactMap { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer \(token)", "Bearer \(token)"])
        seen = []
        for call in [{ _ = try await c.llmEndpointKey(ownerToken: nil) }, { _ = try await c.regenerateLLMEndpointKey(ownerToken: nil) }] {
            do { try await call(); XCTFail("no token, no request") } catch { XCTAssertEqual(error as? LLMEndpointOwnerError, .tokenMissing) }
        }
        XCTAssertTrue(seen.isEmpty, "nothing was sent without a token")
        // An answer with no key is a bad response, not an empty key shown as a key.
        do { _ = try await client("{}").llmEndpointKey(ownerToken: token); XCTFail() } catch { XCTAssertEqual(error as? StudioError, .badResponse) }
    }

    /// The applier reads the owner token when it needs it; a missing one is a sentence for the user and the toggle is
    /// not changed.
    func testTheApplierSaysWhenTheOwnerTokenCannotBeRead() async {
        let d = UserDefaults(suiteName: "llm-owner-\(UUID().uuidString)")!
        var seen = false
        let applier = MeetingSettingsApplier(defaults: d, client: client(record: { _ in seen = true }), ownerToken: { nil })
        let failure = await applier.apply(.llmEndpoint(true))
        XCTAssertEqual(failure, L10nKey.settingsLLMEndpointOwnerMissing.text)
        XCTAssertFalse(seen)
        var auth: String?
        let ok = await MeetingSettingsApplier(defaults: d, client: client(record: { auth = $0.value(forHTTPHeaderField: "Authorization") }),
                                              ownerToken: { self.token }).apply(.llmEndpoint(true))
        XCTAssertNil(ok)
        XCTAssertEqual(auth, "Bearer \(token)")
    }

    // MARK: New key

    @MainActor
    private final class Rotations {
        var inFlight = 0, peak = 0, started = 0
        var gates: [CheckedContinuation<String, Never>] = []
        var results: [Result<String, Error>] = []

        func send() async throws -> String {
            started += 1
            inFlight += 1
            peak = max(peak, inFlight)
            let key = await withCheckedContinuation { gates.append($0) }
            inFlight -= 1
            return key
        }
    }

    /// Taps during a rotation wait their turn; the key shown is the LAST answer, the callback fires once, and two
    /// rotations are never in flight together.
    /// Mutation: LLMEndpointKeyQueue.regenerate, delete `guard !busy else { return }` -> RED (two sends at once).
    @MainActor
    func testNewKeyTapsAreSerializedAndTheLastAnswerWins() async {
        let r = Rotations()
        let q = LLMEndpointKeyQueue(send: { try await r.send() }, finished: { r.results.append($0) })
        q.regenerate()
        await Task.yield()
        q.regenerate()
        q.regenerate()
        await Task.yield()
        XCTAssertEqual(r.started, 1, "the second and third tap wait for the first")
        XCTAssertEqual(r.peak, 1)
        r.gates.removeFirst().resume(returning: "key-1")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(r.started, 2, "the taps coalesce into one further rotation")
        r.gates.removeFirst().resume(returning: "key-2")
        await q.idle()
        XCTAssertEqual(r.peak, 1)
        XCTAssertEqual(r.results.count, 1, "finished fires once, with the last answer only")
        if case .success(let key) = r.results.first { XCTAssertEqual(key, "key-2") } else { XCTFail("no key") }
    }

    /// A settings read that began before a tap, or while one runs, may hold the old key.
    @MainActor
    func testAKeyReadOvertakenByARotationIsStale() async {
        let r = Rotations()
        let q = LLMEndpointKeyQueue(send: { try await r.send() }, finished: { r.results.append($0) })
        let early = q.beginRead()
        XCTAssertFalse(q.isStale(early))
        q.regenerate()
        await Task.yield()
        XCTAssertTrue(q.isStale(early), "a tap overtook it")
        XCTAssertTrue(q.isStale(q.beginRead()), "a read begun during a rotation")
        r.gates.removeFirst().resume(returning: "k")
        await q.idle()
        XCTAssertTrue(q.isStale(early))
        XCTAssertFalse(q.isStale(q.beginRead()), "a read that began after the rotation is current")
    }

    @MainActor
    func testAFailedRotationIsReportedNotShownAsAKey() async {
        let q = LLMEndpointKeyQueue(send: { throw LLMEndpointOwnerError.denied }, finished: { result in
            if case .failure(let e) = result { XCTAssertEqual(e as? LLMEndpointOwnerError, .denied) } else { XCTFail("a key from a failure") }
        })
        q.regenerate()
        await q.idle()
    }
}
