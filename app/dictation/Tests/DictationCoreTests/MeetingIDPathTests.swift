import Foundation
import XCTest
@testable import DictationCore

/// #232 nit — a meeting id goes into a URL path. The ids come from the daemon (`^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`),
/// but the client does not trust that: an id that is not one plain path segment never reaches the wire.
final class MeetingIDPathTests: XCTestCase {
    private let hostile = ["../settings", "..", "a/b", "x?y=1", "a#b", "a%2Fb", "", "a b", "é", "a\nb"]

    private func client(_ seen: @escaping (URLRequest) -> Void) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            seen(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id":"a","status":"done"}"#.utf8), response)
        }
    }

    /// Mutation: MeetingID.isSafe returns true -> RED (every call below reaches the wire).
    func testNoMeetingCallSendsAnIdThatIsNotOnePathSegment() async {
        var sent: [String] = []
        let c = client { sent.append($0.url?.absoluteString ?? "") }
        for id in hostile {
            let calls: [(String, () async throws -> Void)] = [
                ("finish", { _ = try await c.finishMeeting(id: id) }),
                ("meeting", { _ = try await c.meeting(id: id, withTexts: true) }),
                ("notes", { try await c.retryMeetingNotes(id: id) }),
                ("voices", { try await c.retryMeetingVoices(id: id) }),
                ("rename", { _ = try await c.renameMeeting(id: id, title: "t") }),
                ("delete", { try await c.deleteMeeting(id: id) }),
                ("speakers", { _ = try await c.speakers(id: id) }),
                ("editSpeakers", { _ = try await c.editSpeakers(id: id, edits: SpeakerEdits()) }),
            ]
            for (name, call) in calls {
                do {
                    try await call()
                    XCTFail("\(name)(\(id.debugDescription)) reached the daemon")
                } catch {
                    XCTAssertEqual(error as? StudioError, .badResponse, "\(name)(\(id.debugDescription))")
                }
            }
            let probe = await c.probeMeetingAudio(id: id, text: { $0.rawValue })
            if case .failed = probe {} else { XCTFail("probe(\(id.debugDescription)) = \(probe)") }
        }
        XCTAssertEqual(sent, [], "a hostile id was sent: \(sent)")
    }

    /// The daemon's own ids, and the short ones the fixtures use, still pass.
    func testTheDaemonsIdsStillGoThrough() async throws {
        var sent: [String] = []
        let c = client { sent.append($0.url?.path ?? "") }
        _ = try await c.meeting(id: "20261023-143000-abcdef")
        _ = try await c.meeting(id: "m1")
        XCTAssertEqual(sent, ["/v1/meetings/20261023-143000-abcdef", "/v1/meetings/m1"])
    }

    /// The audio URL has no failing form (the player takes a URL): an unsafe id stays inside one segment.
    func testTheAudioURLOfAnUnsafeIDStaysOneSegment() {
        let c = client { _ in }
        for id in hostile {
            let path = c.meetingAudioURL(id: id).path
            XCTAssertEqual(path.split(separator: "/").count, 4, "\(id.debugDescription) -> \(path)")
            XCTAssertFalse(path.contains(".."), path)
        }
    }
}
