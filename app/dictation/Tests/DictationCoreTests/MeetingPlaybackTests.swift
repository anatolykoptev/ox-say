import Foundation
import XCTest
@testable import DictationCore

final class MeetingPlaybackTests: XCTestCase {
    private let turns = [
        TranscriptTurn(id: 0, speaker: "You", time: "0:00", text: "Привет"),
        TranscriptTurn(id: 1, speaker: "Anna", time: "0:12", text: "Бюджет"),
        TranscriptTurn(id: 2, speaker: "You", time: "1:05", text: "План"),
        TranscriptTurn(id: 3, speaker: "Anna", time: "1:05", text: "Да"),
        TranscriptTurn(id: 4, speaker: "You", time: "1:02:03", text: "Конец"),
    ]

    // MARK: the decision

    /// No audio, no play: the affordance is gone, not disabled.
    /// Mutation: PlaybackGate.decide, drop the `audioDeleted` line -> RED.
    func testNoAffordanceWhenTheAudioIsGone() {
        let g = PlaybackGate.decide(audioDeleted: true, recordingRunning: false, status: .done)
        XCTAssertEqual(g, .audioRemoved)
        XCTAssertFalse(g.showsAffordance)
        XCTAssertEqual(PlaybackGate.decide(audioDeleted: true, recordingRunning: true, status: .done), .audioRemoved,
                       "gone wins: there is nothing to explain about a recording")
    }

    /// OxSay never plays a call's audio into the speakers while a recording runs; the line still answers a click.
    /// Mutation: PlaybackGate.decide, drop the `recordingRunning` line -> RED.
    func testNoPlayWhileRecording() {
        let g = PlaybackGate.decide(audioDeleted: false, recordingRunning: true, status: .done)
        XCTAssertEqual(g, .blockedByRecording)
        XCTAssertTrue(g.showsAffordance, "the click is answered with the reason")
        XCTAssertFalse(g.mayPlay)
        XCTAssertEqual(PlaybackGate.decide(audioDeleted: false, recordingRunning: false, status: .done), .allowed)
        XCTAssertTrue(PlaybackGate.allowed.mayPlay)
        XCTAssertEqual(PlaybackGate.decide(audioDeleted: false, recordingRunning: false, status: .recording), .notReady,
                       "that very meeting is still being recorded")
        XCTAssertFalse(PlaybackGate.notReady.showsAffordance)
    }

    // MARK: turn <-> time

    func testTurnTimes() {
        XCTAssertEqual(TurnClock.seconds(of: "0:00"), 0)
        XCTAssertEqual(TurnClock.seconds(of: "1:05"), 65)
        XCTAssertEqual(TurnClock.seconds(of: "1:02:03"), 3723)
        XCTAssertNil(TurnClock.seconds(of: "soon"))
        XCTAssertNil(TurnClock.seconds(of: "1:99"))
        XCTAssertEqual(turns[2].startSeconds, 65)
    }

    /// Clicking a line starts the audio at that line's start, not at 0.
    /// Mutation: PlaybackPlan.start, `.play(from: start)` -> `.play(from: 0)` -> RED.
    func testPlayStartsAtTheTurnsStart() {
        XCTAssertEqual(PlaybackPlan.start(turn: turns[1], gate: .allowed), .play(from: 12))
        XCTAssertEqual(PlaybackPlan.start(turn: turns[4], gate: .allowed), .play(from: 3723))
        XCTAssertEqual(PlaybackPlan.start(turn: turns[1], gate: .blockedByRecording), .refused(.recording))
        XCTAssertEqual(PlaybackPlan.start(turn: turns[1], gate: .audioRemoved), .refused(.unavailable))
        XCTAssertEqual(PlaybackPlan.start(turn: TranscriptTurn(id: 9, speaker: "x", time: "?", text: ""), gate: .allowed), .refused(.unavailable))
    }

    /// While it plays, the current line is the last one that has begun.
    func testTheCurrentTurnFollowsThePosition() {
        XCTAssertNil(TurnClock.currentTurn(at: -1, in: turns))
        XCTAssertEqual(TurnClock.currentTurn(at: 0, in: turns), 0)
        XCTAssertEqual(TurnClock.currentTurn(at: 11.9, in: turns), 0)
        XCTAssertEqual(TurnClock.currentTurn(at: 12, in: turns), 1)
        XCTAssertEqual(TurnClock.currentTurn(at: 64.9, in: turns), 1)
        XCTAssertEqual(TurnClock.currentTurn(at: 70, in: turns), 3, "two turns in one second: the later one")
        XCTAssertEqual(TurnClock.currentTurn(at: 99999, in: turns), 4)
        XCTAssertNil(TurnClock.currentTurn(at: 5, in: []))
    }

    // MARK: hit -> destination

    private func hit(_ f: SearchHit.Field, start: Double? = nil, speaker: String? = nil) -> SearchHit {
        SearchHit(field: f, snippet: "s", start: start, speaker: speaker)
    }

    /// A notes hit (and a title hit) opens Notes; a transcript hit opens the Transcript at its turn.
    /// Mutation: SearchHit.destination, the `.transcript` case returns `.notes` -> RED.
    func testAHitOpensWhereItMatched() {
        XCTAssertEqual(hit(.notes).destination, .notes)
        XCTAssertEqual(hit(.title).destination, .notes)
        XCTAssertEqual(hit(.transcript, start: 65.4, speaker: "Anna").destination, .transcript(start: 65.4, speaker: "Anna"))
        XCTAssertEqual(hit(.transcript).destination, .transcript(start: nil, speaker: nil))
    }

    func testTheHitFindsItsTurn() {
        XCTAssertEqual(TurnLocator.turnID(start: 12.0, speaker: "Anna", in: turns), 1)
        XCTAssertEqual(TurnLocator.turnID(start: 65.9, speaker: "Anna", in: turns), 3, "same second: the speaker decides")
        XCTAssertEqual(TurnLocator.turnID(start: 65.9, speaker: "You", in: turns), 2)
        XCTAssertEqual(TurnLocator.turnID(start: 65.0, speaker: "Nobody", in: turns), 2, "an unknown speaker: the first at that second")
        XCTAssertEqual(TurnLocator.turnID(start: 40, speaker: nil, in: turns), 1, "between turns: the one that had begun")
        XCTAssertNil(TurnLocator.turnID(start: nil, speaker: "Anna", in: turns))
        XCTAssertNil(TurnLocator.turnID(start: 3, speaker: nil, in: []))
    }

    // MARK: the audio address and the probe

    private func client(status: Int, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// The address is the daemon's loopback URL with no credential in it; AVPlayer needs nothing else.
    func testTheAudioURLCarriesNoSecret() {
        let url = client(status: 200).meetingAudioURL(id: "20261023-143000-abcdef")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8094/v1/meetings/20261023-143000-abcdef/audio")
        XCTAssertNil(url.query)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    /// A HEAD before the player: 410 is "removed", never a player error.
    /// Mutation: StudioClient.audioProbe, `case 410:` -> `.failed` -> RED.
    func testTheProbe() async {
        var method = ""
        let ok = await client(status: 200) { method = $0.httpMethod ?? "" }.probeMeetingAudio(id: "m")
        XCTAssertEqual(ok, .available)
        XCTAssertEqual(method, "HEAD")
        let partial = await client(status: 206).probeMeetingAudio(id: "m")
        XCTAssertEqual(partial, .available)
        let gone = await client(status: 410).probeMeetingAudio(id: "m")
        XCTAssertEqual(gone, .removed)
        let busy = await client(status: 409).probeMeetingAudio(id: "m")
        XCTAssertEqual(busy, .stillRecording)
        let e404 = await client(status: 404).probeMeetingAudio(id: "m", text: { $0.rawValue })
        XCTAssertEqual(e404, .failed("meeting.error.not_found"))
        let down = await StudioClient(baseURL: URL(string: "http://127.0.0.1:1")!) { _ in throw URLError(.cannotConnectToHost) }
            .probeMeetingAudio(id: "m", text: { $0.rawValue })
        XCTAssertEqual(down, .failed("meeting.error.daemon_down"))
    }
}
