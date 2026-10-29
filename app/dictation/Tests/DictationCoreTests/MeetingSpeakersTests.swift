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

    /// The daemon refuses a speaker name over 60 characters with a 400 that would lose every other edit in the same
    /// Save: the name is cut first (#252).
    /// Mutation: SpeakerDraft.edits, drop the `MeetingLimits.clamp(..., to: MeetingLimits.nameMax)` on `typed` -> RED.
    func testASpeakerNameIsCutToTheDaemonsCap() {
        var d = SpeakerDraft(from: threeVoices)
        d.names["them:2"] = String(repeating: "Ж", count: 100)
        XCTAssertEqual(d.edits(against: threeVoices).rename["them:2"]?.unicodeScalars.count, MeetingLimits.nameMax)
        // a name typed on a voice folded into a nameless one moves to it: cut as well
        let nameless = SpeakersState(mode: "auto", split: false, speakers: [
            SpeakerInfo(id: "them:1", label: "Speaker 1"), SpeakerInfo(id: "them:2", label: "Speaker 2")])
        var f = SpeakerDraft(from: nameless)
        f.names["them:2"] = String(repeating: "Ж", count: 100)
        f.mergeInto["them:2"] = "them:1"
        let e = f.edits(against: nameless)
        XCTAssertEqual(e.rename["them:1"]?.unicodeScalars.count, MeetingLimits.nameMax)
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

    /// The user merged "Speaker 2" into Anna, then picks a target the daemon would refuse. The merge they already have
    /// must stay: the payload sent has no unmerge (#260 N1).
    /// Mutation: SpeakerDraft.standingMerges, delete the restore of the held target after a rejected pick -> RED.
    func testARejectedNewPickKeepsTheHeldMerge() {
        let held = SpeakersState(mode: "auto", split: false, speakers: [
            SpeakerInfo(id: "them:1", name: "Anna", label: "Anna", speechSeconds: 120, sample: "hello"),
            SpeakerInfo(id: "them:2", label: "Anna", speechSeconds: 30, sample: "yes", mergedTo: "them:1"),
            SpeakerInfo(id: "them:3", label: "Anna", speechSeconds: 12, sample: "agreed", mergedTo: "them:1"),
        ])
        var d = SpeakerDraft(from: held)
        d.mergeInto["them:2"] = "them:3"   // them:3 is itself folded away: a chain
        var e = d.edits(against: held)
        XCTAssertTrue(e.unmerge.isEmpty, "a refused pick is not a request to split the speakers")
        XCTAssertTrue(e.merge.isEmpty)
        d.mergeInto["them:2"] = "them:2"    // a loop
        e = d.edits(against: held)
        XCTAssertTrue(e.unmerge.isEmpty)
        XCTAssertTrue(e.merge.isEmpty)
        d.mergeInto["them:2"] = nil         // a deliberate "—" still splits
        XCTAssertEqual(d.edits(against: held).unmerge, ["them:2"])
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
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), callMode: .ask,
                                     retention: .month, recent: MeetingMenuRecent.from(list))
        let rows = MeetingMenu.rows(state, text: { $0.rawValue })
        let actions = rows.compactMap { row -> MenuAction? in if case .item(_, _, _, let a) = row { return a } else { return nil } }
        XCTAssertEqual(actions.filter { if case .editSpeakers = $0 { return true } else { return false } },
                       [.editSpeakers("a"), .editSpeakers("d"), .editSpeakers("e")])
        XCTAssertTrue(rows.contains(.header("menu.meeting.speakers")))
        let none = MeetingMenu.rows(MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), callMode: .ask, retention: .month),
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
        try NotesExport.refresh(info: again, at: dir, expected: NotesExport.hashes(of: first))
        let notes = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        let text = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let copies = try fm.contentsOfDirectory(atPath: folder.path).count
        XCTAssertEqual(notes, "new notes")
        XCTAssertEqual(text, "**Ivan** [0:03]: hi")
        XCTAssertEqual(copies, 1, "no second copy")
        try fm.removeItem(at: dir)
        var failed = false
        do { try NotesExport.refresh(info: again, at: dir, expected: NotesExport.hashes(of: first)) } catch { failed = true }
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

final class MeetingSpeakersReviewTests: XCTestCase {
    private let pair = SpeakersState(mode: "auto", split: false, speakers: [
        SpeakerInfo(id: "them:1", label: "Speaker 1"), SpeakerInfo(id: "them:2", label: "Speaker 2"),
    ])
    private let four = SpeakersState(mode: "auto", split: false, speakers: [
        SpeakerInfo(id: "them:1", label: "Speaker 1"), SpeakerInfo(id: "them:2", label: "Speaker 2"),
        SpeakerInfo(id: "them:3", label: "Speaker 3"), SpeakerInfo(id: "them:4", label: "Speaker 4"),
    ])

    /// The first merge of a voice that was standing: `case (nil, let new?)`.
    /// Mutation: MeetingSpeakers.swift SpeakerDraft.edits, `case (nil, let new?): e.merge[s.id] = new` -> `break` -> RED.
    func testTheFirstMergeIsSent() {
        var d = SpeakerDraft(from: pair)
        d.mergeInto["them:2"] = "them:1"
        let e = d.edits(against: pair)
        XCTAssertEqual(e.merge, ["them:2": "them:1"])
        XCTAssertTrue(e.unmerge.isEmpty)
    }

    /// Two picks in one Save that the daemon would refuse (a loop, a chain) are not sent: the names typed beside them
    /// are worth more than the second pick, and a dropped pick shows as "—" the next time the panel opens. Merges the
    /// meeting already has are kept first; among new picks the lower id wins.
    /// Mutation: MeetingSpeakers.swift SpeakerDraft.edits, the call `let merges = standingMerges(against: state)` ->
    /// `let merges = mergeInto` -> RED.
    func testALoopOrAChainInOneSaveIsDroppedAndTheNamesStay() {
        var loop = SpeakerDraft(from: pair)
        loop.mergeInto["them:1"] = "them:2"
        loop.mergeInto["them:2"] = "them:1"
        loop.names["them:1"] = "Ivan"
        let e = loop.edits(against: pair)
        XCTAssertEqual(e.merge, ["them:1": "them:2"], "the lower id's pick stands, the one that would close the loop is dropped")
        var chain = SpeakerDraft(from: four)
        chain.mergeInto["them:1"] = "them:2"
        chain.mergeInto["them:3"] = "them:1"
        XCTAssertEqual(chain.edits(against: four).merge, ["them:1": "them:2"], "3 -> 1 -> 2 is a chain")
    }

    func testAMergeTheMeetingAlreadyHasOutranksANewPickThatWouldChainOnIt() {
        let held = SpeakersState(mode: "auto", split: false, speakers: [
            SpeakerInfo(id: "them:1", label: "Speaker 1"), SpeakerInfo(id: "them:2", label: "Speaker 2"),
            SpeakerInfo(id: "them:3", label: "Speaker 1", mergedTo: "them:1"),
        ])
        var d = SpeakerDraft(from: held)
        d.mergeInto["them:1"] = "them:2"
        let e = d.edits(against: held)
        XCTAssertTrue(e.merge.isEmpty, "them:3 stays folded into them:1, so them:1 cannot move")
        XCTAssertTrue(e.unmerge.isEmpty, "and the standing merge is not taken back")
    }

    /// The daemon forgets the name of a voice it folds away, so the name typed on it goes to the voice it joins when
    /// that one has none.
    /// Mutation: MeetingSpeakers.swift SpeakerDraft.edits, delete the `carry` line `e.rename[into] = typed` -> RED.
    func testANameTypedOnAVoiceThatIsMergedMovesToItsTarget() {
        var d = SpeakerDraft(from: pair)
        d.names["them:2"] = " Olga "
        d.mergeInto["them:2"] = "them:1"
        var e = d.edits(against: pair)
        XCTAssertEqual(e.merge, ["them:2": "them:1"])
        XCTAssertEqual(e.rename, ["them:1": "Olga"], "carried to the target; none for the voice that is folded away")
        d.names["them:1"] = "Ivan"
        e = d.edits(against: pair)
        XCTAssertEqual(e.rename, ["them:1": "Ivan"], "a target that has a name keeps it")
    }

    /// The list says "reason", not "kind": a Mac-wide reason is said once per reason, and `too_long` belongs to one
    /// recording so it is said for each.
    /// Mutations: MeetingSpeakers.swift MeetingMenuRecent.from, key on the kind (one flag) -> RED
    /// (`models_missing` hidden behind `os_too_old`); delete the `reason != "too_long"` exemption -> RED.
    func testAMacProblemIsSaidOncePerReasonAndTooLongForEveryRecording() {
        func m(_ id: String, _ reason: String) -> MeetingInfo {
            MeetingInfo(id: id, title: id, status: .done, warnings: ["diarization_unavailable"], diarReason: reason)
        }
        let list = [m("a", "os_too_old"), m("b", "models_missing"), m("c", "os_too_old"), m("d", "too_long"), m("e", "too_long")]
        XCTAssertEqual(MeetingMenuRecent.from(list, limit: 10).map(\.id), ["a", "b", "d", "e"])
    }

    func testNoTryAgainWhenTheAudioIsGone() {
        let info = MeetingInfo.decode(Data(#"{"id":"a","status":"done","warnings":["diarization_failed"],"diar_reason":"engine_error","audio_deleted":true}"#.utf8))
        XCTAssertEqual(info?.audioDeleted, true)
        XCTAssertEqual(MeetingInfo.decode(Data(#"{"id":"a","status":"done"}"#.utf8))?.audioDeleted, false)
        let list = [
            MeetingInfo(id: "gone", title: "Gone", status: .done, warnings: ["diarization_failed"], diarReason: "engine_error", audioDeleted: true),
            MeetingInfo(id: "here", title: "Here", status: .done, warnings: ["diarization_failed"], diarReason: "bad_output"),
        ]
        let recent = MeetingMenuRecent.from(list)
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), callMode: .ask,
                                     retention: .month, recent: recent)
        let actions = MeetingMenu.rows(state, text: { $0.rawValue }).compactMap { row -> MenuAction? in
            if case .item(_, _, _, let a) = row { return a } else { return nil }
        }
        XCTAssertTrue(actions.contains(.retryVoices("here")))
        XCTAssertFalse(actions.contains(.retryVoices("gone")), "the daemon would refuse: there is no audio to transcribe again")
    }

    /// The answer to the edit says whether the notes are final. The client does not guess it from what it sent.
    /// Mutations: MeetingSpeakers.swift SpeakersState.decode, `obj["notes_queued"] as? Bool ?? false` -> `?? true` -> RED;
    /// -> `false` literal -> RED.
    func testTheAnswerToAnEditSaysWhetherTheNotesAreQueued() async throws {
        XCTAssertEqual(SpeakersState.decode(Data(#"{"mode":"auto","speakers":[],"notes_queued":true}"#.utf8))?.notesQueued, true)
        XCTAssertEqual(SpeakersState.decode(Data(#"{"mode":"auto","speakers":[],"notes_queued":false}"#.utf8))?.notesQueued, false)
        XCTAssertEqual(SpeakersState.decode(Data(#"{"mode":"auto","speakers":[]}"#.utf8))?.notesQueued, false)
        // a rename the daemon could not substitute safely comes back queued: the client follows the answer
        let c = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            (Data(#"{"mode":"auto","split":false,"speakers":[{"id":"them:1","label":"Ivan"}],"notes_queued":true}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var e = SpeakerEdits()
        e.rename = ["them:1": "Ivan"]
        let state = try await c.editSpeakers(id: "m1", edits: e)
        XCTAssertTrue(state.notesQueued)
    }
}

final class NotesExportRefreshTests: XCTestCase {
    private func exported() throws -> (folder: URL, dir: URL, info: MeetingInfo) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ox-refresh-\(UUID().uuidString)", isDirectory: true)
        let info = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_700_000_000), status: .done, notesMD: "old notes", transcriptMD: "old text")
        return (folder, try NotesExport.write(info: info, in: folder), info)
    }

    func testTheHashIsSHA256OfTheText() {
        let info = MeetingInfo(id: "a", status: .done, notesMD: "abc", transcriptMD: "")
        XCTAssertEqual(NotesExport.hashes(of: info), [
            "notes.md": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "transcript.md": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ])
        XCTAssertNil(NotesExport.hashes(of: MeetingInfo(id: "a", status: .done, notesMD: "abc"))["transcript.md"])
    }

    /// A copy the user edited is theirs: it is not replaced, the caller keeps the stale flag, and the other file is
    /// left alone too so the folder never holds new notes beside an old transcript.
    /// Mutation: NotesExport.swift refresh, delete the `edited` check (`if !edited.isEmpty { return .keptEdited(edited) }`) -> RED.
    func testAnEditedCopyIsKeptWhole() throws {
        let (folder, dir, first) = try exported()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hashes = NotesExport.hashes(of: first)
        try Data("my own notes".utf8).write(to: dir.appendingPathComponent("notes.md"))
        var again = first
        again.notesMD = "new notes"
        again.transcriptMD = "new text"
        let result = try NotesExport.refresh(info: again, at: dir, expected: hashes)
        XCTAssertEqual(result, .keptEdited(["notes.md"]))
        let got1 = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(got1, "my own notes")
        let got2 = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(got2, "old text")
    }

    func testAnUntouchedCopyIsRefreshedAndLeavesNoTemporaryFiles() throws {
        let (folder, dir, first) = try exported()
        defer { try? FileManager.default.removeItem(at: folder) }
        var again = first
        again.notesMD = "new notes"
        again.transcriptMD = "new text"
        let got3 = try NotesExport.refresh(info: again, at: dir, expected: NotesExport.hashes(of: first))
        XCTAssertEqual(got3, .refreshed)
        let got4 = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(got4, "new notes")
        let got5 = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(got5, ["notes.md", "transcript.md"])
        // no stored hash for a file that is there: it cannot be proven untouched, so it is kept
        let got6 = try NotesExport.refresh(info: again, at: dir, expected: [:])
        XCTAssertEqual(got6, .keptEdited(["notes.md", "transcript.md"]))
    }

    /// Both new texts are staged before either file is replaced: a failure while staging changes nothing.
    /// Mutation: NotesExport.swift refresh, replace each file right after staging it (move the `try replace(...)` into
    /// the staging loop) -> RED (notes.md is new, transcript.md old).
    func testAFailureWhileStagingLeavesTheCopyAsItWas() throws {
        let (folder, dir, first) = try exported()
        defer { try? FileManager.default.removeItem(at: folder) }
        var again = first
        again.notesMD = "new notes"
        again.transcriptMD = "new text"
        struct Boom: Error {}
        var staged = 0
        do {
            _ = try NotesExport.refresh(info: again, at: dir, expected: NotesExport.hashes(of: first), stage: { data, url in
                staged += 1
                if staged == 2 { throw Boom() }
                try data.write(to: url)
            })
            XCTFail("want the failure")
        } catch is Boom {}
        let got7 = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertEqual(got7, "old notes")
        let got8 = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(got8, "old text")
        let got9 = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(got9, ["notes.md", "transcript.md"], "the staged file is removed")
    }

    func testTheHashLedgerKeepsWhatWasWritten() {
        let d = UserDefaults(suiteName: "ox-hashes-\(UUID().uuidString)")!
        XCTAssertTrue(MeetingSettings.exportHashes("a", d).isEmpty)
        MeetingSettings.setExportHashes("a", ["notes.md": "h1", "transcript.md": "h2"], d)
        XCTAssertEqual(MeetingSettings.exportHashes("a", d), ["notes.md": "h1", "transcript.md": "h2"])
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
