import Foundation
import XCTest
@testable import DictationCore

final class MeetingSearchTests: XCTestCase {
    private let json = #"""
    {"meetings":[{"id":"m1","title":"Plan","started":"2026-10-20T10:00:00Z","status":"done","hits":[
      {"field":"title","snippet":"Plan"},
      {"field":"notes","snippet":"…the budget is approved…"},
      {"field":"transcript","snippet":"budget first","start":0,"speaker":"Anna"},
      {"field":"future","snippet":"ignored"}]}],"truncated":true,"skipped":2}
    """#

    func testDecodeTheDaemonsShape() throws {
        let r = try XCTUnwrap(MeetingSearchResult.decode(Data(json.utf8)))
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.skipped, 2)
        let m = try XCTUnwrap(r.meetings.first)
        XCTAssertEqual(m.id, "m1")
        XCTAssertEqual(m.hits.map(\.field), [.title, .notes, .transcript], "an unknown field is left out, not a failure")
        XCTAssertEqual(m.hits[2].start, 0, "a start of 0 is still a start")
        XCTAssertEqual(m.hits[2].speaker, "Anna")
        XCTAssertNil(m.hits[1].start)
        XCTAssertNotNil(m.started)
        XCTAssertNil(MeetingSearchResult.decode(Data("[]".utf8)))
        XCTAssertEqual(MeetingSearchResult.decode(Data(#"{"meetings":[]}"#.utf8))?.meetings.count, 0)
    }

    /// Truncated and skipped are said in one short line, nothing when both are clear.
    func testFootnote() {
        let t: (L10nKey) -> String = { $0 == .searchSkipped ? "skipped %d" : $0.rawValue }
        XCTAssertNil(MeetingSearchResult(meetings: []).footnote(text: t))
        XCTAssertEqual(MeetingSearchResult(meetings: [], truncated: true).footnote(text: t), "search.truncated")
        XCTAssertEqual(MeetingSearchResult(meetings: [], skipped: 3).footnote(text: t), "skipped 3")
        XCTAssertEqual(MeetingSearchResult(meetings: [], truncated: true, skipped: 3).footnote(text: t), "search.truncated skipped 3")
    }

    /// Blank input is no query; a longer one is cut to the daemon's 200 characters (not bytes).
    func testNormalize() {
        XCTAssertNil(MeetingSearch.normalize(""))
        XCTAssertNil(MeetingSearch.normalize(" \n\t "))
        XCTAssertEqual(MeetingSearch.normalize("  бюджет  "), "бюджет")
        XCTAssertEqual(MeetingSearch.normalize(String(repeating: "ё", count: 250))?.unicodeScalars.count, 200)
        XCTAssertEqual(MeetingSearch.normalize(String(repeating: "a", count: 200))?.count, 200)
    }

    private func client(status: Int, headers: [String: String] = [:], body: String = "{}", record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    /// The query is percent-encoded whole: a "+" or "&" in it is text, not a separator.
    func testTheQueryTravelsWholeAndPlain() async {
        var seen: URLRequest?
        let c = client(status: 200, body: json) { seen = $0 }
        _ = await c.searchMeetings(query: "c++ & бюджет=1")
        XCTAssertEqual(seen?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/search")
        let items = URLComponents(url: seen!.url!, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.name, "q")
        XCTAssertEqual(items?.first?.value?.removingPercentEncoding, "c++ & бюджет=1")
        XCTAssertFalse(items?.first?.value?.contains("+") ?? true, "+ must be %2B, or the daemon reads a space")
        XCTAssertFalse(items?.first?.value?.contains("&") ?? true)
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"), "the daemon asks for no secret")
    }

    /// 429 is "retry shortly", with the daemon's Retry-After; it is never an error sentence.
    /// Mutation: StudioClient.searchMeetings, `case 429:` -> returns `.failed(...)` -> RED.
    func testA429IsBusyNotAnError() async {
        let c = client(status: 429, headers: ["Retry-After": "2"])
        let a = await c.searchMeetings(query: "x")
        XCTAssertEqual(a, .busy(retryAfter: 2))
        let none = await client(status: 429).searchMeetings(query: "x")
        XCTAssertEqual(none, .busy(retryAfter: 1), "no header: the daemon's own default")
        let big = await client(status: 429, headers: ["Retry-After": "600"]).searchMeetings(query: "x")
        XCTAssertEqual(big, .busy(retryAfter: MeetingSearch.maxRetryDelay))
        let zero = await client(status: 429, headers: ["Retry-After": "0"]).searchMeetings(query: "x")
        XCTAssertEqual(zero, .busy(retryAfter: MeetingSearch.debounce), "never a hot loop")
    }

    func testFailuresHaveSentences() async {
        let down = StudioClient(baseURL: URL(string: "http://127.0.0.1:1")!) { _ in throw URLError(.cannotConnectToHost) }
        let a = await down.searchMeetings(query: "x", text: { $0.rawValue })
        XCTAssertEqual(a, .failed("meeting.error.daemon_down"))
        let bad = await client(status: 200, body: "nope").searchMeetings(query: "x", text: { $0.rawValue })
        XCTAssertEqual(bad, .failed("meeting.error.bad_response"))
        let e500 = await client(status: 500, body: #"{"error":{"message":"boom"}}"#).searchMeetings(query: "x", text: { $0.rawValue })
        XCTAssertEqual(e500, .failed("meeting.error.generic"), "the daemon's words never reach the window")
    }

    // MARK: the state machine

    private func result(_ id: String) -> MeetingSearchResult {
        MeetingSearchResult(meetings: [SearchedMeeting(id: id, title: id, started: nil, status: .done, hits: [SearchHit(field: .title, snippet: id)])])
    }

    func testTypingWaitsThenSearches() {
        var s = MeetingSearchState()
        XCTAssertEqual(MeetingSearch.reduce(&s, .typed("бюд")), [.cancelInFlight, .startTimer(generation: 1, delay: MeetingSearch.debounce)])
        XCTAssertEqual(s.phase, .searching)
        XCTAssertEqual(MeetingSearch.reduce(&s, .timerFired(generation: 1)), [.run(generation: 1, query: "бюд")])
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .result(result("a")))), [])
        XCTAssertEqual(s.phase, .results(result("a")))
    }

    /// A key typed while the first timer runs makes the first timer and answer stale.
    /// Mutation: MeetingSearch.reduce, `.timerFired`, drop `generation == s.generation` -> RED.
    func testAStaleTimerDoesNotSearch() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("a"))
        _ = MeetingSearch.reduce(&s, .typed("ab"))
        XCTAssertEqual(MeetingSearch.reduce(&s, .timerFired(generation: 1)), [], "the first timer is stale")
        XCTAssertEqual(MeetingSearch.reduce(&s, .timerFired(generation: 2)), [.run(generation: 2, query: "ab")])
    }

    /// An old answer arriving after a newer query began never replaces it.
    /// Mutation: MeetingSearch.reduce, `.answered`, drop `generation == s.generation` -> RED.
    func testAStaleAnswerDoesNotOverwriteANewerQuery() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("a"))
        _ = MeetingSearch.reduce(&s, .timerFired(generation: 1))
        _ = MeetingSearch.reduce(&s, .typed("ab"))
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .result(result("old")))), [])
        XCTAssertEqual(s.phase, .searching, "the old answer is dropped")
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .busy(retryAfter: 1))), [], "so is an old 429")
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .failed("x"))), [])
        XCTAssertEqual(s.phase, .searching)
    }

    func testTypingCancelsTheRequestInFlight() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("a"))
        XCTAssertTrue(MeetingSearch.reduce(&s, .typed("ab")).contains(.cancelInFlight))
        XCTAssertEqual(MeetingSearch.reduce(&s, .typed("")), [.cancelInFlight])
    }

    /// Blank input returns to the plain list; the same text again does nothing.
    func testBlankGoesBackAndSameTextIsQuiet() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("abc"))
        _ = MeetingSearch.reduce(&s, .timerFired(generation: 1))
        _ = MeetingSearch.reduce(&s, .answered(generation: 1, .result(result("a"))))
        XCTAssertEqual(MeetingSearch.reduce(&s, .typed("abc ")), [], "a trailing space is the same query")
        XCTAssertEqual(s.phase, .results(result("a")))
        XCTAssertEqual(MeetingSearch.reduce(&s, .typed("  ")), [.cancelInFlight])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.query, "")
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .result(result("late")))), [])
        XCTAssertEqual(s.phase, .idle, "an answer after the field was cleared is dropped")
    }

    func testNoResults() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("zzz"))
        _ = MeetingSearch.reduce(&s, .timerFired(generation: 1))
        _ = MeetingSearch.reduce(&s, .answered(generation: 1, .result(MeetingSearchResult(meetings: []))))
        XCTAssertEqual(s.phase, .noResults)
    }

    /// A 429 stays "searching" and tries again after the daemon's delay; it is no error. After a few tries a quiet
    /// "busy" line with a button, still not an error sentence.
    /// Mutation: MeetingSearch.reduce, `.busy` -> `s.phase = .failed(...)` -> RED.
    func testBusyRetriesQuietly() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("a"))
        _ = MeetingSearch.reduce(&s, .timerFired(generation: 1))
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .busy(retryAfter: 1))), [.startTimer(generation: 1, delay: 1)])
        XCTAssertEqual(s.phase, .searching)
        XCTAssertEqual(MeetingSearch.reduce(&s, .timerFired(generation: 1)), [.run(generation: 1, query: "a")])
        for _ in 1..<MeetingSearch.maxRetries { _ = MeetingSearch.reduce(&s, .answered(generation: 1, .busy(retryAfter: 1))) }
        XCTAssertEqual(MeetingSearch.reduce(&s, .answered(generation: 1, .busy(retryAfter: 1))), [])
        XCTAssertEqual(s.phase, .busy)
        XCTAssertEqual(MeetingSearch.reduce(&s, .retry), [.cancelInFlight, .run(generation: 2, query: "a")])
        XCTAssertEqual(s.phase, .searching)
    }

    func testFailureIsSaidAndRetryable() {
        var s = MeetingSearchState()
        _ = MeetingSearch.reduce(&s, .typed("a"))
        _ = MeetingSearch.reduce(&s, .timerFired(generation: 1))
        _ = MeetingSearch.reduce(&s, .answered(generation: 1, .failed("down")))
        XCTAssertEqual(s.phase, .failed("down"))
        XCTAssertEqual(MeetingSearch.reduce(&s, .typed("a")).count, 2, "the same text after a failure searches again")
    }
}
