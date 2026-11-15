import Foundation
import XCTest
@testable import DictationCore

/// A scripted daemon: every request is recorded, and `answer` decides the status and body of each.
final class GlossaryStub {
    var requests: [URLRequest] = []
    var answer: (URLRequest) -> (Int, String)

    init(_ answer: @escaping (URLRequest) -> (Int, String) = { _ in (200, #"{"pairs":[]}"#) }) { self.answer = answer }

    var studio: StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            self.requests.append(request)
            let (status, body) = self.answer(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    var lines: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" } }
}

let glossaryToken = String(repeating: "ab12", count: 16)

func pairJSON(_ id: String, _ heard: String, _ meant: String, _ status: String, seen: Int = 1) -> String {
    #"{"id":"\#(id)","heard":"\#(heard)","meant":"\#(meant)","status":"\#(status)","seen":\#(seen)}"#
}

final class GlossaryClientTests: XCTestCase {
    private func client(_ stub: GlossaryStub, token: @escaping () -> String? = { glossaryToken }) -> GlossaryClient {
        GlossaryClient(studio: stub.studio, ownerToken: token)
    }

    /// Mutation: GlossaryClient.owner(_:_:method:body:), delete the `setValue("Bearer …", forHTTPHeaderField: "Authorization")` line -> RED.
    func testGlossaryOwnerCallsCarryTheBearer() async throws {
        let stub = GlossaryStub { _ in (200, "{}") }
        let c = client(stub)
        try await c.approve(id: "1a2b3c4d")
        try await c.reject(id: "1a2b3c4d")
        try await c.edit(id: "1a2b3c4d", meant: "OxSay")
        try await c.purge(id: "1a2b3c4d")
        XCTAssertEqual(stub.lines, ["POST /v1/glossary/1a2b3c4d/approve", "POST /v1/glossary/1a2b3c4d/reject",
                                    "POST /v1/glossary/1a2b3c4d/edit", "DELETE /v1/glossary/1a2b3c4d"])
        for request in stub.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + glossaryToken, request.url?.path ?? "")
        }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(stub.requests[2].httpBody)) as? [String: Any]
        XCTAssertEqual(body?["meant"] as? String, "OxSay")
        XCTAssertNil(stub.requests[3].httpBody, "a DELETE carries no body")
    }

    /// Listing and filing are open on the daemon: the owner key does not travel with them.
    func testGlossaryListAndFilingSendNoBearer() async throws {
        let stub = GlossaryStub { request in
            request.httpMethod == "POST" ? (200, pairJSON("1a2b3c4d", "воксей", "OxSay", "candidate")) : (200, #"{"pairs":[]}"#)
        }
        let c = client(stub)
        _ = try await c.pairs()
        let pair = try await c.add(heard: "воксей", meant: "OxSay")
        XCTAssertEqual(pair.id, "1a2b3c4d")
        XCTAssertEqual(pair.status, .candidate)
        for request in stub.requests { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
    }

    func testGlossaryNoTokenSendsNothing() async {
        let stub = GlossaryStub()
        do { try await client(stub, token: { nil }).purge(id: "1a2b3c4d"); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? GlossaryError, .ownerTokenMissing)
        }
        XCTAssertEqual(stub.requests.count, 0)
    }

    /// The token is asked for at each request, so a regenerated token works on the next click without a restart.
    func testGlossaryTheTokenIsReadAtRequestTime() async throws {
        let stub = GlossaryStub { _ in (200, "{}") }
        var current = String(repeating: "0a", count: 32)
        let c = client(stub, token: { current })
        try await c.approve(id: "aa")
        current = glossaryToken
        try await c.approve(id: "aa")
        XCTAssertEqual(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer " + String(repeating: "0a", count: 32), "Bearer " + glossaryToken])
    }

    func testGlossaryA403IsOwnerDeniedAndOtherRefusalsKeepTheDaemonsWords() async {
        let denied = GlossaryStub { _ in (403, #"{"error":{"message":"owner-only"}}"#) }
        do { try await client(denied).approve(id: "aa"); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? GlossaryError, .ownerDenied)
        }
        let refused = GlossaryStub { _ in (400, #"{"error":{"message":"meant must be at most 4 words"}}"#) }
        do { try await client(refused).edit(id: "aa", meant: "x"); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? StudioError, .refused(status: 400, message: "meant must be at most 4 words"))
        }
    }

    /// An id from a daemon answer is one path segment or nothing is sent.
    func testGlossaryAnUnsafeIdIsNeverSent() async {
        let stub = GlossaryStub()
        for id in ["../x", "a/b", "a?b", "", "a%2Fb"] {
            do { try await client(stub).purge(id: id); XCTFail("\(id) must throw") } catch {
                XCTAssertEqual(error as? StudioError, .badResponse)
            }
        }
        XCTAssertEqual(stub.requests.count, 0)
    }

    func testGlossaryDecodeKeepsAnUnknownStatusAndSkipsHalfRows() async throws {
        let rows = [pairJSON("a1", "один", "1", "candidate", seen: 3), pairJSON("a2", "два", "2", "future"),
                    #"{"id":"a3","meant":"no heard"}"#]
        let stub = GlossaryStub { _ in (200, #"{"pairs":[\#(rows.joined(separator: ","))]}"#) }
        let got = try await client(stub).pairs()
        XCTAssertEqual(got.map(\.id), ["a1", "a2"])
        XCTAssertEqual(got[0].seen, 3)
        XCTAssertEqual(got[1].status, .unknown("future"))
    }

    func testGlossaryAnAnswerThatIsNotAListIsBad() async {
        let stub = GlossaryStub { _ in (200, "[]") }
        do { _ = try await client(stub).pairs(); XCTFail("must throw") } catch {
            XCTAssertEqual(error as? StudioError, .badResponse)
        }
    }
}

final class DaemonHomeTests: XCTestCase {
    private func plist(_ env: [String: String]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: ["EnvironmentVariables": env], format: .xml, options: 0)
    }

    private let user = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testGlossaryHomeComesFromTheLaunchAgentElseTheDaemonsDefault() {
        XCTAssertEqual(DaemonHome.url(agentPlist: plist(["OX_SAY_HOME": "/Volumes/x/ox-say"]), userHome: user).path, "/Volumes/x/ox-say")
        let fallback = "/Users/someone/Library/Application Support/ox-say"
        XCTAssertEqual(DaemonHome.url(agentPlist: nil, userHome: user).path, fallback)
        XCTAssertEqual(DaemonHome.url(agentPlist: plist(["PATH": "/bin"]), userHome: user).path, fallback)
        XCTAssertEqual(DaemonHome.url(agentPlist: plist(["OX_SAY_HOME": "relative/dir"]), userHome: user).path, fallback,
                       "a relative home is not one the daemon would use")
    }

    private func home(writing token: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let token { try token.write(to: dir.appendingPathComponent(OwnerToken.fileName), atomically: true, encoding: .utf8) }
        return dir
    }

    func testGlossaryOwnerTokenReadsOnlyWhatTheDaemonWrites() throws {
        let good = try home(writing: glossaryToken + "\n")
        let none = try home(writing: nil)
        let short = try home(writing: "feed1234\n")
        let upper = try home(writing: glossaryToken.uppercased())
        let split = try home(writing: String(glossaryToken.prefix(30)) + "\r\nX-Evil: 1\r\n" + String(glossaryToken.prefix(20)))
        XCTAssertEqual(OwnerToken.read(home: good), glossaryToken)
        XCTAssertNil(OwnerToken.read(home: none), "no file")
        XCTAssertNil(OwnerToken.read(home: short), "too short")
        XCTAssertNil(OwnerToken.read(home: upper), "the daemon writes lowercase hex")
        XCTAssertNil(OwnerToken.read(home: split), "a header-splitting file is no token")
    }
}

@MainActor
final class GlossaryModelTests: XCTestCase {
    private func model(_ stub: GlossaryStub, token: @escaping () -> String? = { glossaryToken }) -> GlossaryModel {
        GlossaryModel(client: GlossaryClient(studio: stub.studio, ownerToken: token))
    }

    private func list(_ rows: String...) -> String { #"{"pairs":[\#(rows.joined(separator: ","))]}"# }

    /// After an action the list on screen is the daemon's: the stub's second listing differs from the first.
    /// Mutation: GlossaryModel.act(_:), delete the `await reload()` after the action -> RED.
    func testGlossaryReloadsFromTheDaemonAfterEveryAction() async {
        var listings = 0
        let stub = GlossaryStub { request in
            if request.httpMethod == "GET" {
                listings += 1
                return (200, listings == 1 ? self.list(pairJSON("a1", "один", "1", "candidate"))
                                           : self.list(pairJSON("a1", "один", "1", "active"), pairJSON("a9", "новый", "N", "candidate")))
            }
            return (200, "{}")
        }
        let m = model(stub)
        await m.reload()
        XCTAssertEqual(m.pairs.map(\.status), [.candidate])
        await m.approve("a1")
        XCTAssertEqual(m.pairs.map(\.id), ["a1", "a9"], "the model shows what the daemon listed after the action, not its own edit")
        XCTAssertEqual(m.pairs[0].status, .active)
        XCTAssertEqual(stub.lines, ["GET /v1/glossary", "POST /v1/glossary/a1/approve", "GET /v1/glossary"])
    }

    /// A refused action says why and still reads the list again.
    func testGlossaryARefusedActionShowsTheReasonAndReloads() async {
        let stub = GlossaryStub { request in
            request.httpMethod == "GET" ? (200, self.list(pairJSON("a1", "один", "1", "candidate")))
                                        : (400, #"{"error":{"message":"meant must be at most 4 words"}}"#)
        }
        let m = model(stub)
        await m.reload()
        await m.edit("a1", meant: "one two three four five")
        XCTAssertEqual(m.problem, "meant must be at most 4 words")
        XCTAssertEqual(m.pairs.map(\.id), ["a1"])
        XCTAssertEqual(stub.lines.last, "GET /v1/glossary")
        m.dismissProblem()
        XCTAssertNil(m.problem)
    }

    func testGlossaryFilterAndCounts() async {
        let stub = GlossaryStub { _ in
            (200, self.list(pairJSON("a1", "а", "1", "candidate"), pairJSON("a2", "б", "2", "active"),
                            pairJSON("a3", "в", "3", "rejected"), pairJSON("a4", "г", "4", "active")))
        }
        let m = model(stub)
        await m.reload()
        XCTAssertEqual(m.visible.count, 4)
        m.filter = .active
        XCTAssertEqual(m.visible.map(\.id), ["a2", "a4"])
        m.filter = .candidate
        XCTAssertEqual(m.visible.map(\.id), ["a1"])
        m.filter = .rejected
        XCTAssertEqual(m.visible.map(\.id), ["a3"])
        XCTAssertEqual(GlossaryFilter.allCases.map { m.count($0) }, [4, 1, 2, 1])
    }

    /// The owner is present: a pair added in the app is filed, then approved with the id the daemon returned.
    /// Mutation: GlossaryModel.add, drop the `approve` call -> RED.
    func testGlossaryAddFilesThenApproves() async {
        let stub = GlossaryStub { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/v1/glossary"): return (200, pairJSON("feedface", "воксей", "OxSay", "candidate"))
            case ("GET", _): return (200, self.list(pairJSON("feedface", "воксей", "OxSay", "active")))
            default: return (200, "{}")
            }
        }
        let m = model(stub)
        let ok = await m.add(heard: " воксей ", meant: "OxSay ")
        XCTAssertTrue(ok)
        XCTAssertEqual(stub.lines, ["POST /v1/glossary", "POST /v1/glossary/feedface/approve", "GET /v1/glossary"])
        let body = try? JSONSerialization.jsonObject(with: stub.requests[0].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["heard"] as? String, "воксей")
        XCTAssertEqual(body?["meant"] as? String, "OxSay")
        XCTAssertEqual(m.pairs.first?.status, .active)
    }

    func testGlossaryAddThatTheDaemonRefusesReportsFailure() async {
        let stub = GlossaryStub { request in
            request.httpMethod == "POST" ? (400, #"{"error":{"message":"invalid pair"}}"#) : (200, self.list())
        }
        let m = model(stub)
        let ok = await m.add(heard: "x", meant: "y")
        XCTAssertFalse(ok)
        XCTAssertEqual(m.problem, "invalid pair")
        XCTAssertFalse(stub.lines.contains { $0.contains("approve") }, "nothing to approve when the filing failed")
    }

    /// Without the owner key the page still lists; the owner actions send nothing and say why.
    func testGlossaryWithoutTheOwnerKeyTheListStillLoads() async {
        let stub = GlossaryStub { _ in (200, self.list(pairJSON("a1", "один", "1", "candidate"))) }
        let m = model(stub, token: { nil })
        XCTAssertFalse(m.ownerAvailable)
        await m.reload()
        XCTAssertEqual(m.pairs.count, 1)
        XCTAssertFalse(m.ownerAvailable)
        await m.delete("a1")
        XCTAssertEqual(m.problem, GlossaryError.ownerTokenMissing.message())
        XCTAssertFalse(stub.requests.contains { $0.httpMethod == "DELETE" })
    }

    /// A key that appears after the page opened is picked up by the next read.
    func testGlossaryTheOwnerKeyAppearingEnablesTheActions() async {
        var token: String?
        let stub = GlossaryStub { _ in (200, self.list()) }
        let m = model(stub, token: { token })
        XCTAssertFalse(m.ownerAvailable)
        token = glossaryToken
        await m.reload()
        XCTAssertTrue(m.ownerAvailable)
    }

    /// A failed first read is not an empty list; a later good read replaces it, and a failed refresh keeps the good list.
    func testGlossaryAFailedReadIsNotAnEmptyList() async {
        var up = false
        let stub = GlossaryStub { _ in up ? (200, self.list(pairJSON("a1", "один", "1", "active"))) : (500, "") }
        let m = model(stub)
        await m.reload()
        guard case .failed = m.load else { return XCTFail("a 500 is a failed read, got \(m.load)") }
        XCTAssertTrue(m.pairs.isEmpty)
        up = true
        await m.reload()
        XCTAssertEqual(m.load, .loaded)
        up = false
        await m.reload()
        guard case .failed = m.load else { return XCTFail("the refresh failed") }
        XCTAssertEqual(m.pairs.map(\.id), ["a1"], "the last good list stays on screen")
    }

    private func fourPairs() -> GlossaryStub {
        GlossaryStub { request in
            request.httpMethod == "GET"
                ? (200, self.list(pairJSON("a1", "а", "1", "candidate"), pairJSON("a2", "б", "2", "active"), pairJSON("a3", "в", "3", "rejected")))
                : (200, "{}")
        }
    }

    /// Switching the filter drops a selection the new filter hides, and keeps one it still shows.
    /// Mutation: GlossaryModel.dropHiddenSelection(), delete the `selection = nil` -> RED.
    func testGlossaryAFilterChangeDropsAHiddenSelection() async {
        let m = model(fourPairs())
        await m.reload()
        m.selection = "a1"
        XCTAssertEqual(m.selectedPair?.id, "a1")
        m.filter = .active
        XCTAssertNil(m.selection, "a1 is a candidate: the active filter hides it")
        XCTAssertNil(m.selectedPair)
        m.selection = "a2"
        m.filter = .all
        XCTAssertEqual(m.selection, "a2", "a row the new filter still shows stays selected")
        m.selection = "a1"
        m.filter = .rejected
        XCTAssertNil(m.selection)
        m.selection = "a1"
        XCTAssertNil(m.selection, "a hidden row cannot be selected at all")
    }

    /// An action on an id the filter hides sends nothing: the owner cannot see that pair.
    /// Mutation: GlossaryModel.actOnVisible(_:_:), delete the `guard visible.contains` -> RED.
    func testGlossaryActionsActOnlyOnAVisiblePair() async {
        let stub = fourPairs()
        let m = model(stub)
        await m.reload()
        m.filter = .active
        await m.approve("a1")
        await m.reject("a1")
        await m.edit("a1", meant: "x")
        await m.delete("a1")
        XCTAssertEqual(stub.lines, ["GET /v1/glossary"], "nothing but the load: a1 is hidden by the filter")
        await m.delete("a2")
        XCTAssertEqual(stub.lines.suffix(2), ["DELETE /v1/glossary/a2", "GET /v1/glossary"])
    }

    /// A reload that removes the selected pair clears the selection.
    func testGlossaryAReloadThatDropsTheSelectedPairClearsIt() async {
        var rows = [pairJSON("a1", "а", "1", "active")]
        let stub = GlossaryStub { _ in (200, self.list(rows.joined(separator: ",") == "" ? "" : rows[0])) }
        let m = model(stub)
        await m.reload()
        m.selection = "a1"
        rows = [pairJSON("a2", "б", "2", "active")]
        await m.reload()
        XCTAssertNil(m.selection)
    }

    /// `edit` says whether it went through: true only when the daemon accepted it. A hidden pair, a refusal and an
    /// action already in flight are all false, so the sheet stays open.
    /// Mutation: GlossaryModel.edit/actOnVisible, return true on the hidden-pair guard -> RED.
    func testGlossaryEditReportsWhetherItWentThrough() async {
        var refuse = false
        let stub = GlossaryStub { request in
            if request.httpMethod == "GET" { return (200, self.list(pairJSON("a1", "а", "1", "candidate"), pairJSON("a2", "б", "2", "active"))) }
            return refuse ? (400, #"{"error":{"message":"invalid pair"}}"#) : (200, "{}")
        }
        let m = model(stub)
        await m.reload()
        let sent = await m.edit("a1", meant: "ok")
        XCTAssertTrue(sent)
        m.filter = .active
        let hidden = await m.edit("a1", meant: "ok")
        XCTAssertFalse(hidden, "nothing was sent for a pair the filter hides")
        XCTAssertEqual(stub.lines.filter { $0.contains("/edit") }.count, 1)
        refuse = true
        let refused = await m.edit("a2", meant: "bad")
        XCTAssertFalse(refused)
        XCTAssertEqual(m.problem, "invalid pair")
    }
}
