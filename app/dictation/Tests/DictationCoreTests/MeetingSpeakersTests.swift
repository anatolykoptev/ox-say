import Foundation
import XCTest
@testable import DictationCore

final class MeetingSpeakersTests: XCTestCase {
    private let threeVoices = SpeakersState(mode: "auto", split: false, speakers: [
        SpeakerInfo(id: "them:1", name: "Ivan", label: "Ivan", speechSeconds: 120, sample: "thanks for having us"),
        SpeakerInfo(id: "them:2", label: "Speaker 2", speechSeconds: 90, sample: "let us start with the budget"),
        SpeakerInfo(id: "them:3", label: "Ivan", speechSeconds: 12, sample: "agreed", mergedTo: "them:1"),
    ])

    func testDecodeTheDaemonsAnswer() throws {
        let json = #"{"mode":"offer","split":false,"speakers":[{"id":"them","label":"Other","speech_s":210.5,"sample":"hello"}]}"#
        let s = try XCTUnwrap(SpeakersState.decode(Data(json.utf8)))
        XCTAssertEqual(s.mode, "offer")
        XCTAssertTrue(s.offersSplit)
        XCTAssertEqual(s.speakers, [SpeakerInfo(id: "them", label: "Other", speechSeconds: 210.5, sample: "hello")])
        XCTAssertFalse(s.speakers[0].isVoice)
        XCTAssertNil(SpeakersState.decode(Data("[]".utf8)))
        XCTAssertEqual(SpeakersState.decode(Data(#"{"speakers":[{"label":"x"},{"id":"them:1","merged_to":""}]}"#.utf8))?.speakers.map(\.id), ["them:1"],
                       "a speaker without an id is dropped; an empty merged_to is not merged")
    }

    func testOfferingTheSplitStopsOnceItIsTaken() {
        XCTAssertFalse(SpeakersState(mode: "offer", split: true).offersSplit)
        XCTAssertFalse(SpeakersState(mode: "auto").offersSplit)
        XCTAssertEqual(threeVoices.liveVoices.map(\.id), ["them:1", "them:2"])
    }

    /// Only what changed goes to the daemon. A repeated Save with nothing changed sends nothing,
    /// which matters: every edit makes the daemon write the notes again.
    /// Mutation: SpeakerDraft.edits, change `if now != s.name.trimmingCharacters(in: .whitespacesAndNewlines)`
    /// to `if true` -> RED (an untouched draft renames everybody).
    func testAnUntouchedDraftSendsNothing() {
        let d = SpeakerDraft(from: threeVoices)
        XCTAssertTrue(d.edits(against: threeVoices).isEmpty)
        var spaced = d
        spaced.names["them:1"] = "  Ivan "
        XCTAssertTrue(spaced.edits(against: threeVoices).isEmpty, "spaces around a name are not a rename")
    }

    func testRenameMergeUnmergeAndSplit() {
        var d = SpeakerDraft(from: threeVoices)
        d.names["them:2"] = " Olga "
        d.names["them:1"] = ""
        d.mergeInto["them:3"] = nil
        var e = d.edits(against: threeVoices)
        XCTAssertEqual(e.rename, ["them:2": "Olga", "them:1": ""], "an emptied field clears the name")
        XCTAssertEqual(e.unmerge, ["them:3"])
        XCTAssertTrue(e.merge.isEmpty)
        d.mergeInto["them:3"] = "them:2"
        e = d.edits(against: threeVoices)
        XCTAssertEqual(e.unmerge, ["them:3"], "a changed target is an unmerge and a merge")
        XCTAssertEqual(e.merge, ["them:3": "them:2"])
        let offer = SpeakersState(mode: "offer", split: false, speakers: [SpeakerInfo(id: "them", label: "Other")])
        var s = SpeakerDraft(from: offer)
        s.split = true
        XCTAssertEqual(s.edits(against: offer).split, true)
        XCTAssertNil(SpeakerDraft(from: offer).edits(against: offer).split)
    }

    /// A voice can be folded into a voice that is still standing, never into itself, a merged one,
    /// or one that others were folded into (no chains).
    /// Mutation: SpeakerDraft.mergeTargets, delete the `guard !mergeInto.values.contains(id)` line -> RED.
    func testMergeTargetsAvoidChains() {
        var d = SpeakerDraft(from: threeVoices)
        XCTAssertEqual(d.mergeTargets(for: "them:2", in: threeVoices).map(\.id), ["them:1"], "them:3 is merged away, them:2 is itself")
        XCTAssertEqual(d.mergeTargets(for: "them:1", in: threeVoices).map(\.id), [], "them:3 was folded into them:1: it cannot move on")
        d.mergeInto["them:3"] = nil
        XCTAssertEqual(d.mergeTargets(for: "them:1", in: threeVoices).map(\.id), ["them:2", "them:3"])
    }

    func testTheRequestBodyIsStableAndMinimal() throws {
        var e = SpeakerEdits()
        XCTAssertEqual(String(decoding: e.body(), as: UTF8.self), "{}")
        e.rename = ["them:2": "Olga"]
        e.unmerge = ["them:3", "them:1"]
        e.split = true
        XCTAssertEqual(String(decoding: e.body(), as: UTF8.self), #"{"rename":{"them:2":"Olga"},"split":true,"unmerge":["them:1","them:3"]}"#)
    }

    func testTheMenuListsOnlyMeetingsWithVoicesThatAreReady() {
        let list = [
            MeetingInfo(id: "a", title: "Plan", status: .done, voiceMode: "auto"),
            MeetingInfo(id: "b", title: "One to one", status: .done),
            MeetingInfo(id: "c", title: "Running", status: .summarizing, voiceMode: "auto"),
            MeetingInfo(id: "d", title: "Pair", status: .transcribed, voiceMode: "offer"),
            MeetingInfo(id: "e", title: "Old", status: .done, voiceMode: "auto"),
            MeetingInfo(id: "f", title: "Older", status: .done, voiceMode: "auto"),
            MeetingInfo(id: "g", title: "Oldest", status: .done, voiceMode: "auto"),
        ]
        XCTAssertEqual(MeetingMenuRecent.from(list).map(\.id), ["a", "d", "e"])
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), autoStart: true,
                                     retention: .month, recent: MeetingMenuRecent.from(list))
        let rows = MeetingMenu.rows(state, text: { $0.rawValue })
        let actions = rows.compactMap { row -> MenuAction? in if case .item(_, _, _, let a) = row { return a } else { return nil } }
        XCTAssertEqual(actions.filter { if case .editSpeakers = $0 { return true } else { return false } },
                       [.editSpeakers("a"), .editSpeakers("d"), .editSpeakers("e")])
        XCTAssertTrue(rows.contains(.header("menu.meeting.speakers")))
        let none = MeetingMenu.rows(MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), autoStart: true, retention: .month),
                                    text: { $0.rawValue })
        XCTAssertFalse(none.contains(.header("menu.meeting.speakers")), "no header without a meeting to name")
    }

    func testDecodeTheVoiceModeOfAMeeting() throws {
        XCTAssertEqual(MeetingInfo.decode(Data(#"{"id":"a","status":"done","voice_mode":"offer"}"#.utf8))?.voiceMode, "offer")
        XCTAssertNil(MeetingInfo.decode(Data(#"{"id":"a","status":"done"}"#.utf8))?.voiceMode)
    }

    /// The label word travels with the meeting so the transcript prints "Спикер 2" for a Russian user.
    func testExportRefreshReplacesTheTextsInPlaceAndRefusesAMissingFolder() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ox-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let first = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_700_000_000), status: .done, notesMD: "old notes", transcriptMD: "old text")
        let dir = try NotesExport.write(info: first, in: folder)
        var again = first
        again.notesMD = "new notes"
        again.transcriptMD = "**Ivan** [0:03]: hi"
        try NotesExport.refresh(info: again, at: dir)
        let notes = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        let text = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let copies = try fm.contentsOfDirectory(atPath: folder.path).count
        XCTAssertEqual(notes, "new notes")
        XCTAssertEqual(text, "**Ivan** [0:03]: hi")
        XCTAssertEqual(copies, 1, "no second copy")
        try fm.removeItem(at: dir)
        var failed = false
        do { try NotesExport.refresh(info: again, at: dir) } catch { failed = true }
        XCTAssertTrue(failed, "a folder the user moved away is an error, not a silent recreate")
    }

    func testTheExportLedgerKeepsPathsAndStaleness() {
        let d = UserDefaults(suiteName: "ox-speakers-\(UUID().uuidString)")!
        XCTAssertNil(MeetingSettings.exportPath("a", d))
        MeetingSettings.setExportPath("a", "/n/2026 Plan", d)
        XCTAssertEqual(MeetingSettings.exportPath("a", d), "/n/2026 Plan")
        MeetingSettings.setExportStale("a", true, d)
        XCTAssertEqual(MeetingSettings.exportStale(d), ["a"])
        MeetingSettings.setExportStale("a", false, d)
        XCTAssertTrue(MeetingSettings.exportStale(d).isEmpty)
    }
}

final class MeetingSpeakersClientTests: XCTestCase {
    private func client(_ answer: String, status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(answer.utf8), response)
        }
    }

    func testReadAndEditSpeakers() async throws {
        var seen: [URLRequest] = []
        let c = client(#"{"mode":"auto","split":false,"speakers":[{"id":"them:1","label":"Speaker 1"}]}"#) { seen.append($0) }
        let s = try await c.speakers(id: "m1")
        XCTAssertEqual(s.speakers.count, 1)
        XCTAssertEqual(seen[0].httpMethod, "GET")
        XCTAssertEqual(seen[0].url?.path, "/v1/meetings/m1/speakers")
        var e = SpeakerEdits()
        e.rename = ["them:1": "Ivan"]
        _ = try await c.editSpeakers(id: "m1", edits: e)
        XCTAssertEqual(seen[1].httpMethod, "PATCH")
        let sent = try XCTUnwrap(seen[1].httpBody)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), #"{"rename":{"them:1":"Ivan"}}"#)
    }

    func testARefusalCarriesTheDaemonsWords() async {
        let refused = client(#"{"error":{"message":"meeting: speakers: no speaker \"them:9\""}}"#, status: 400)
        do { _ = try await refused.editSpeakers(id: "m1", edits: SpeakerEdits()); XCTFail("want a refusal") }
        catch { XCTAssertTrue("\(error)".contains("no speaker")) }
    }

    func testCreateSendsTheSpeakerWordOnlyWhenGiven() async throws {
        var bodies: [[String: Any]] = []
        let c = client(#"{"id":"20261023-143000-abcdef","dir":"/d","status":"recording"}"#) {
            bodies.append((try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) ?? [:])
        }
        _ = try await c.createMeeting(title: "", source: "", me: "A", them: "B", speaker: "Спикер", echoRisk: false)
        _ = try await c.createMeeting(title: "", source: "", me: "A", them: "B", echoRisk: false)
        XCTAssertEqual((bodies[0]["labels"] as? [String: String])?["speaker"], "Спикер")
        XCTAssertNil((bodies[1]["labels"] as? [String: String])?["speaker"])
    }
}
