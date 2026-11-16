import Foundation
import XCTest
@testable import DictationCore

/// The window's side of live captions: reading the daemon's answer, keeping the lines once each, polling only while a
/// meeting is being recorded, and the sentence under the list.
final class MeetingLiveTests: XCTestCase {
    private func answer(_ rows: [(Int, String, String)], next: Int, state: String = #"{"enabled":true,"recording":true,"active":true}"#) -> LiveAnswer {
        let segments = rows.map { #"{"seq":\#($0.0),"channel":"\#($0.1)","start":1.5,"end":3,"text":"\#($0.2)"}"# }.joined(separator: ",")
        let json = #"{"id":"20261115-100000-abcdef","segments":[\#(segments)],"next":\#(next),"state":\#(state)}"#
        return LiveAnswer.decode(Data(json.utf8))!
    }

    func testDecodeReadsTheCaptionsTheCursorAndTheState() throws {
        let a = answer([(1, "me", "Hello"), (2, "them", "  Hi there ")], next: 2,
                       state: #"{"enabled":true,"recording":true,"active":true,"lagging":true,"paused":"dictation"}"#)
        XCTAssertEqual(a.captions.map(\.seq), [1, 2])
        XCTAssertEqual(a.captions.map(\.channel), [.me, .them])
        XCTAssertEqual(a.captions[1].text, "Hi there")
        XCTAssertEqual(a.next, 2)
        XCTAssertTrue(a.state.lagging)
        XCTAssertEqual(a.state.paused, "dictation")
        XCTAssertNil(LiveAnswer.decode(Data(#"{"id":"x"}"#.utf8)), "an answer without segments is not the daemon's")
    }

    /// Polling with the cursor the feed holds yields every line once, however the answers arrive: repeated, late, or
    /// cut into pages.
    /// Mutation: LiveFeed.apply, `caption.seq > cursor` -> `caption.seq >= cursor` -> RED (the last line repeats on the
    /// next poll); drop the cursor update `cursor = caption.seq` -> RED (every line repeats).
    func testTheFeedKeepsEveryLineOnceWhateverTheOrderOfTheAnswers() {
        var feed = LiveFeed()
        feed.apply(answer([(1, "me", "one"), (2, "them", "two")], next: 2))
        XCTAssertEqual(feed.cursor, 2)
        feed.apply(answer([(1, "me", "one"), (2, "them", "two")], next: 2)) // the same answer again
        feed.apply(answer([(2, "them", "two"), (3, "me", "three")], next: 3)) // an overlapping one
        feed.apply(answer([(1, "me", "one")], next: 1)) // a late, older one
        XCTAssertEqual(feed.captions.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(feed.cursor, 3)
        feed.apply(answer([], next: 3))
        XCTAssertEqual(feed.captions.count, 3)
    }

    /// A line of a channel this app does not know is not shown, but the cursor still passes it: otherwise every poll
    /// would ask for it again and the feed would stall behind it.
    /// Mutation: LiveFeed.apply, delete the `if answer.next > cursor, ...` line -> RED (the cursor stays at 1).
    func testTheCursorPassesALineItCannotShow() {
        var feed = LiveFeed()
        feed.apply(answer([(1, "me", "one")], next: 1))
        let json = #"{"segments":[{"seq":2,"channel":"future","start":0,"end":1,"text":"x"}],"next":2,"state":{}}"#
        feed.apply(LiveAnswer.decode(Data(json.utf8))!)
        XCTAssertEqual(feed.captions.map(\.seq), [1])
        XCTAssertEqual(feed.cursor, 2)
    }

    /// Mutation: MeetingLive.swift LivePolling.needed, drop `selected.status == .recording` -> RED (a finished meeting is polled).
    func testLiveIsPolledOnlyWhileTheChosenMeetingIsRecorded() {
        let recording = MeetingInfo(id: "a", status: .recording)
        XCTAssertTrue(LivePolling.needed(visible: true, selected: recording))
        XCTAssertFalse(LivePolling.needed(visible: false, selected: recording), "a hidden window polls nothing")
        XCTAssertFalse(LivePolling.needed(visible: true, selected: nil))
        for status in [MeetingInfo.Status.queued, .transcribing, .transcribed, .summarizing, .done, .failed] {
            XCTAssertFalse(LivePolling.needed(visible: true, selected: MeetingInfo(id: "a", status: status)), "\(status)")
        }
    }

    func testTheSentenceUnderTheList() {
        XCTAssertNil(LiveNotice.key(for: nil))
        XCTAssertNil(LiveNotice.key(for: LiveCaptionState()))
        XCTAssertEqual(LiveNotice.key(for: LiveCaptionState(enabled: false, active: false)), .meetingLiveOff)
        XCTAssertEqual(LiveNotice.key(for: LiveCaptionState(lagging: true, paused: "memory")), .meetingLiveBehind)
        XCTAssertEqual(LiveNotice.key(for: LiveCaptionState(lagging: true, problem: "recognizer")), .meetingLiveUnavailable,
                       "the speech engine being out of reach is said as such, not as 'behind'")
    }

    /// The request: a plain GET with the cursor as `after`, for a safe meeting id only.
    /// Mutation: StudioClient.liveCaptions, `"after"` -> `"since"` -> RED.
    func testTheClientAsksForCaptionsAfterTheCursor() async throws {
        var seen: URLRequest?
        let client = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            seen = request
            let body = #"{"id":"x","segments":[],"next":7,"state":{"recording":true}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let a = try await client.liveCaptions(id: "20261115-100000-abcdef", after: 7)
        XCTAssertEqual(seen?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/20261115-100000-abcdef/live")
        XCTAssertEqual(URLComponents(url: seen!.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "after", value: "7")])
        XCTAssertEqual(a.next, 7)
        do {
            _ = try await client.liveCaptions(id: "../etc", after: 0)
            XCTFail("an id that is not one plain segment must not be sent")
        } catch {
            XCTAssertEqual(error as? StudioError, .badResponse)
        }
    }
}
