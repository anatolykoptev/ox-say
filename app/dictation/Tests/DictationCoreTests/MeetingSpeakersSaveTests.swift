import Foundation
import XCTest
@testable import DictationCore

/// #371: the menu's Speakers panel saves what can be saved and names what it refused (it used to drop the whole save
/// on one bad name), and a voice that is being folded into another is not refused for a name that would never go out.
final class MeetingSpeakersSaveTests: XCTestCase {
    private let voices = SpeakersState(mode: "auto", split: false, speakers: [
        SpeakerInfo(id: "them:1", label: "Speaker 1"),
        SpeakerInfo(id: "them:2", label: "Speaker 2"),
        SpeakerInfo(id: "them:3", label: "Speaker 3"),
    ])

    /// Runs `body` with the English strings (the shim has no setUp/tearDown, so each test scopes it itself).
    private func english<T>(_ body: () throws -> T) throws -> T {
        let saved = L10nBundle.bundle
        defer { L10nBundle.bundle = saved }
        let en = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/en.lproj")
        L10nBundle.bundle = try XCTUnwrap(Bundle(path: en.path))
        return try body()
    }

    /// Rename three voices, one to "?!": the two good names go out and the bad one is named, not silently dropped.
    /// Mutation: SpeakerDraft.savePlan, `edits: edits(against: state)` -> `edits: refused.isEmpty ? edits(against: state) : SpeakerEdits()` -> RED.
    func testOneRefusedNameDoesNotDropTheOthers() {
        var d = SpeakerDraft(from: voices)
        d.names["them:1"] = "Anna"
        d.names["them:2"] = "?!"
        d.names["them:3"] = "Boris"
        let plan = d.savePlan(against: voices)
        XCTAssertEqual(plan.edits.rename, ["them:1": "Anna", "them:3": "Boris"])
        XCTAssertEqual(plan.refused.map(\.id), ["them:2"])
        XCTAssertEqual(plan.refused.map(\.label), ["Speaker 2"])
    }

    /// The sentence names the refused voice(s).
    /// Mutation: SpeakersSavePlan.refusedSentence, drop the labels argument from the format -> RED.
    func testTheSentenceNamesTheRefusedVoices() throws {
        try english {
            var d = SpeakerDraft(from: voices)
            d.names["them:2"] = "?!"
            d.names["them:3"] = "…"
            let sentence = d.savePlan(against: voices).refusedSentence() ?? ""
            XCTAssertEqual(sentence, "Not saved: Speaker 2, Speaker 3. A name needs at least one letter or digit.")
        }
    }

    func testACleanDraftHasNoRefusalSentence() {
        var d = SpeakerDraft(from: voices)
        d.names["them:1"] = "Anna"
        let plan = d.savePlan(against: voices)
        XCTAssertNil(plan.refusedSentence())
        XCTAssertTrue(plan.refused.isEmpty)
        XCTAssertFalse(plan.edits.isEmpty)
    }

    /// Only a refused name: nothing to send, the sentence still names the voice.
    func testOnlyARefusedNameSendsNothing() throws {
        try english {
            var d = SpeakerDraft(from: voices)
            d.names["them:2"] = "?!"
            let plan = d.savePlan(against: voices)
            XCTAssertTrue(plan.edits.isEmpty)
            XCTAssertTrue((plan.refusedSentence() ?? "").contains("Speaker 2"))
        }
    }

    /// One notice per save (#383 review): the refused names are appended to the sentence the save would have said, and the
    /// copy's own sentence stands in for "names saved" when the export had one -- never a second banner.
    /// Mutation: SpeakersSaved.notice, drop `base + " " + refused` (return `refused`) -> RED.
    /// Mutation: SpeakersSaved.notice, drop the `exportSentence ??` (always "Names saved.") -> RED.
    func testASaveSaysOneThingWithTheRefusedNamesInIt() throws {
        try english {
            var d = SpeakerDraft(from: voices)
            d.names["them:1"] = "Anna"
            d.names["them:2"] = "?!"
            let plan = d.savePlan(against: voices)
            let refused = plan.refusedSentence()
            XCTAssertEqual(SpeakersSaved.notice(refused: refused, notesQueued: false, exportSentence: nil),
                           "Names saved. Not saved: Speaker 2. A name needs at least one letter or digit.")
            XCTAssertEqual(SpeakersSaved.notice(refused: refused, notesQueued: true, exportSentence: nil),
                           "Speakers saved. The notes are being written again. Not saved: Speaker 2. A name needs at least one letter or digit.")
            XCTAssertEqual(SpeakersSaved.notice(refused: refused, notesQueued: false, exportSentence: "The copy was edited, so it was kept."),
                           "The copy was edited, so it was kept. Not saved: Speaker 2. A name needs at least one letter or digit.",
                           "the export sentence is kept, not buried by \"saved\"")
            XCTAssertEqual(SpeakersSaved.notice(refused: nil, notesQueued: false, exportSentence: nil), "Names saved.")
            XCTAssertEqual(SpeakersSaved.notice(refused: nil, notesQueued: false, exportSentence: "The copy was edited, so it was kept."),
                           "The copy was edited, so it was kept.")
        }
    }

    /// The re-open after the split offer is taken is independent of refused names.
    /// Mutation: SpeakersSaved.reopens, `wasOffer && !answer.offersSplit` -> `false` -> RED.
    func testThePanelReopensWhenTheSplitWasTaken() {
        let offer = SpeakersState(mode: "offer", split: false, speakers: [])
        let taken = SpeakersState(mode: "offer", split: true, speakers: [])
        XCTAssertTrue(SpeakersSaved.reopens(wasOffer: true, answer: taken))
        XCTAssertFalse(SpeakersSaved.reopens(wasOffer: true, answer: offer))
        XCTAssertFalse(SpeakersSaved.reopens(wasOffer: false, answer: taken))
    }

    /// #371.2: a leftover "?!" in a voice that is folded into another goes nowhere, so it blocks nothing.
    /// Mutation: SpeakerDraft.refusedSpeakers, delete the `newlyFolded` skip -> RED.
    func testAVoiceBeingMergedAwayIsNotRefused() {
        var d = SpeakerDraft(from: voices)
        d.names["them:2"] = "?!"
        d.mergeInto["them:2"] = "them:1"
        XCTAssertNil(d.refusal(against: voices), "the name is not sent, the voice joins them:1")
        XCTAssertTrue(d.savePlan(against: voices).refused.isEmpty)
        XCTAssertNil(d.edits(against: voices).rename["them:2"])
        XCTAssertEqual(d.edits(against: voices).merge, ["them:2": "them:1"])
    }

    /// A pick the daemon would refuse (a chain) is left out, so that voice is not being merged away: its bad name counts.
    func testAMergeThatCannotStandDoesNotExcuseTheName() {
        var d = SpeakerDraft(from: voices)
        d.names["them:2"] = "?!"
        d.mergeInto["them:2"] = "them:1"
        d.mergeInto["them:1"] = "them:3"  // them:1 folded away: them:2 -> them:1 would be a chain; the lower id's pick wins
        let plan = d.savePlan(against: voices)
        let stands = d.edits(against: voices).merge["them:2"] != nil
        XCTAssertEqual(plan.refused.map(\.id).contains("them:2"), !stands)
    }

    /// The main window's red line and the menu agree: a voice that is not being folded away and holds "?!" is refused.
    func testARefusedNameStillBlocksTheMainWindow() {
        var d = SpeakerDraft(from: voices)
        d.names["them:2"] = "?!"
        XCTAssertEqual(d.refusal(against: voices), .speakersNameNeedsLetter)
    }

    /// The menu's save goes through the plan, never back to refuse-everything.
    /// Mutation: MeetingController.editSpeakers, put back `if let refusal = draft.refusal(against: state) { host.notify(refusal.text); return }` -> RED.
    func testTheMenuSavesThroughThePlan() throws {
        let text = try MeetingWiringTests.stripComments(String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/MeetingController.swift"), encoding: .utf8))
        let start = try XCTUnwrap(text.range(of: "private func editSpeakers(_ id: String) {"))
        let tail = String(text[start.upperBound...])
        let end = try XCTUnwrap(tail.range(of: "func saveSpeakers(id: String"))
        let body = String(tail[..<end.lowerBound])
        // The decisions (one notice, nothing sent when all is refused) are SpeakersSaveRun's, see SpeakersSaveRunTests;
        // what stays pinned is that the panel goes through the plan and the runner.
        XCTAssertTrue(body.contains("let plan = draft.savePlan(against: state, owner: owner)"))
        XCTAssertTrue(body.contains("(try? await host.client.meeting(id: id))?.ownerLabel"))
        XCTAssertTrue(body.contains("try await SpeakersSaveRun.run(\n                        plan: plan,"))
        XCTAssertTrue(body.contains("notify: { host.notify($0) }"))
        XCTAssertEqual(body.components(separatedBy: "host.notify(").count - 1, 2, "the runner's notify and the failure's own")
        XCTAssertTrue(body.contains("SpeakersSaved.reopens(wasOffer: wasOffer, answer: state)"), "the split re-open survives a partial save")
        XCTAssertFalse(body.contains(".refusal(against:"), "all-or-nothing is back")
    }

    /// #371.3: the OK press commits with the keeping variant, so a field holding one huge Character does not clear the name.
    /// Mutation: SpeakersPrompt, `cap(field.stringValue, to: MeetingLimits.nameMax, keeping: ...)` -> plain `cap(field.stringValue, to: MeetingLimits.nameMax)` -> RED.
    func testTheCommitKeepsTheStoredNameOnAHugeCharacter() throws {
        let src = try MeetingWiringTests.stripComments(String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/SpeakersPrompt.swift"), encoding: .utf8))
        XCTAssertTrue(src.contains("MeetingLimits.cap(field.stringValue, to: MeetingLimits.nameMax, keeping: draft.names[id] ?? \"\")"))
        XCTAssertFalse(src.contains("MeetingLimits.cap(field.stringValue, to: MeetingLimits.nameMax)"))
        // and the function it calls keeps the name
        let huge = "e" + String(repeating: "\u{301}", count: 70)
        XCTAssertEqual(MeetingLimits.cap(huge, to: MeetingLimits.nameMax, keeping: "Ivan"), "Ivan")
    }

    // MARK: #371.6 duplicate names

    private let named = SpeakersState(mode: "auto", split: false, speakers: [
        SpeakerInfo(id: "them:1", name: "Bob", label: "Bob"),
        SpeakerInfo(id: "them:2", name: "Carol", label: "Carol"),
        SpeakerInfo(id: "them:3", label: "Speaker 3"),
    ])

    /// A name another voice already carries is not sent (the daemon would 400 the whole save); the rest goes out.
    /// The daemon compares trimmed and case-folded (strings.EqualFold) against the label of every other live voice.
    /// Mutation: SpeakerDraft.nameKey, fold -> identity (raw compare) -> RED.
    func testADuplicateNameIsNotSentAndTheRestIs() {
        var d = SpeakerDraft(from: voices)
        d.names["them:1"] = "speaker 2"          // case variant of another voice's default label
        d.names["them:3"] = "Anna"
        let plan = d.savePlan(against: voices)
        XCTAssertEqual(plan.edits.rename, ["them:3": "Anna"])
        XCTAssertEqual(plan.duplicates.map(\.id), ["them:1"])
        XCTAssertTrue(plan.refused.isEmpty)
    }

    func testWhitespaceAndCaseVariantsAreDuplicates() {
        var d = SpeakerDraft(from: named)
        d.names["them:3"] = "  cAROL \t"
        XCTAssertEqual(d.savePlan(against: named).duplicates.map(\.id), ["them:3"])
        XCTAssertTrue(d.savePlan(against: named).edits.rename.isEmpty)
    }

    /// Non-ASCII case folding like Go's EqualFold (Cyrillic here).
    func testCyrillicCaseVariantIsADuplicate() {
        let s = SpeakersState(mode: "auto", speakers: [SpeakerInfo(id: "them:1", name: "Анна", label: "Анна"), SpeakerInfo(id: "them:2", label: "Speaker 2")])
        var d = SpeakerDraft(from: s)
        d.names["them:2"] = "аННА"
        XCTAssertEqual(d.savePlan(against: s).duplicates.map(\.id), ["them:2"])
    }

    /// Final names count, not the old ones: swapping two names is fine.
    func testASwapIsNotADuplicate() {
        var d = SpeakerDraft(from: named)
        d.names["them:1"] = "Carol"
        d.names["them:2"] = "Bob"
        let plan = d.savePlan(against: named)
        XCTAssertEqual(plan.edits.rename, ["them:1": "Carol", "them:2": "Bob"])
        XCTAssertTrue(plan.duplicates.isEmpty)
    }

    /// Two voices typed the same new name: the lower id keeps it, the other is named.
    func testTwoVoicesTypedTheSameNameKeepsTheFirst() {
        var d = SpeakerDraft(from: voices)
        d.names["them:1"] = "Anna"
        d.names["them:2"] = "anna"
        let plan = d.savePlan(against: voices)
        XCTAssertEqual(plan.edits.rename, ["them:1": "Anna"])
        XCTAssertEqual(plan.duplicates.map(\.id), ["them:2"])
    }

    /// A voice folded away is not a speaker any more; its old label is free. A voice's own label in another case is no duplicate.
    func testMergedAwayVoicesAndTheVoiceItselfAreNotRivals() {
        var d = SpeakerDraft(from: named)
        d.mergeInto["them:2"] = "them:3"            // Carol is folded away
        d.names["them:2"] = ""                      // and her name goes with her (a typed one would move to them:3)
        d.names["them:1"] = "carol"                 // free now
        XCTAssertTrue(d.savePlan(against: named).duplicates.isEmpty)
        var own = SpeakerDraft(from: named)
        own.names["them:1"] = "BOB"
        XCTAssertEqual(own.savePlan(against: named).edits.rename, ["them:1": "BOB"])
        XCTAssertTrue(own.savePlan(against: named).duplicates.isEmpty)
    }

    /// Invalid and duplicate at once: reported once, as invalid.
    func testAnInvalidDuplicateIsReportedOnceAsInvalid() throws {
        let s = SpeakersState(mode: "auto", speakers: [SpeakerInfo(id: "them:1", label: "?!"), SpeakerInfo(id: "them:2", label: "Speaker 2")])
        var d = SpeakerDraft(from: s)
        d.names["them:2"] = "?!"
        let plan = d.savePlan(against: s)
        XCTAssertEqual(plan.refused.map(\.id), ["them:2"])
        XCTAssertTrue(plan.duplicates.isEmpty)
        try english {
            let sentence = plan.notSavedSentence() ?? ""
            XCTAssertEqual(sentence.components(separatedBy: "Not saved").count - 1, 1)
            XCTAssertFalse(sentence.contains("Another speaker"))
        }
    }

    /// One sentence, own reason, both reasons when both happen.
    func testTheDuplicateSentenceHasItsOwnReason() throws {
        try english {
            var d = SpeakerDraft(from: named)
            d.names["them:3"] = "bob"
            let plan = d.savePlan(against: named)
            XCTAssertEqual(plan.duplicateSentence(), "Not saved: Speaker 3. Another speaker already has that name.")
            XCTAssertEqual(plan.notSavedSentence(), plan.duplicateSentence())
            let both = SpeakersSavePlan(edits: SpeakerEdits(), refused: [SpeakerInfo(id: "them:1", label: "Bob")], duplicates: plan.duplicates)
            XCTAssertEqual(both.notSavedSentence(),
                           "Not saved: Bob. A name needs at least one letter or digit. Not saved: Speaker 3. Another speaker already has that name.")
        }
    }

    /// #384.5: the window's line names the voice, with the plan's own sentence.
    func testTheWindowsRefusalLineNamesTheVoice() throws {
        try english {
            var d = SpeakerDraft(from: voices)
            d.names["them:2"] = "?!"
            XCTAssertEqual(d.windowSave(against: voices).line, "Not saved: Speaker 2. A name needs at least one letter or digit.")
            d.names["them:2"] = "Anna"
            XCTAssertNil(d.windowSave(against: voices).line)
        }
    }

    /// #371.6 in the window: a draft the plan knows the daemon would answer with a 400 is never sent. Save is disabled
    /// (`edits` nil) and the line names the voice with the duplicate reason; a draft without one is sent as it is.
    /// Mutation: SpeakerDraft.windowSave, `edits: (line != nil || plan.edits.isEmpty) ? nil : plan.edits` -> `edits: plan.edits.isEmpty ? nil : plan.edits` -> RED.
    func testTheWindowNeverSendsADuplicate() throws {
        try english {
            var d = SpeakerDraft(from: named)
            d.names["them:3"] = "bob"
            d.names["them:2"] = "Dora"                         // a fine rename beside the duplicate: still not sent
            let save = d.windowSave(against: named)
            XCTAssertNil(save.edits, "Save is disabled while a name is taken")
            XCTAssertEqual(save.line, "Not saved: Speaker 3. Another speaker already has that name.")
            d.names["them:3"] = "Dan"
            let ok = d.windowSave(against: named)
            XCTAssertNil(ok.line)
            XCTAssertEqual(ok.edits?.rename, ["them:2": "Dora", "them:3": "Dan"])
            XCTAssertNil(SpeakerDraft(from: named).windowSave(against: named).edits, "nothing changed: nothing to save")
        }
    }

    // MARK: the owner's label (#371.6)

    /// The daemon counts the person who recorded the call as a speaker: a name equal to theirs (case, spaces) is a duplicate.
    /// Mutation: SpeakerDraft.dropDuplicates, delete `if key == ownerKey { return true }` -> RED.
    func testANameEqualToTheOwnersIsADuplicate() throws {
        var d = SpeakerDraft(from: named)
        d.names["them:3"] = " ANNA "
        d.names["them:1"] = "Robert"
        let plan = d.savePlan(against: named, owner: "Anna")
        XCTAssertEqual(plan.edits.rename, ["them:1": "Robert"])
        XCTAssertEqual(plan.duplicates.map(\.id), ["them:3"])
        XCTAssertNil(d.windowSave(against: named, owner: "anna").edits)
        // not known (a failed read): left to the daemon, nothing is guessed
        XCTAssertTrue(d.savePlan(against: named).duplicates.isEmpty)
        XCTAssertTrue(d.savePlan(against: named, owner: "  ").duplicates.isEmpty)
    }

    /// The meeting the daemon serves carries the owner's label as `labels.me`.
    func testTheMeetingDecodesTheOwnersLabel() throws {
        let json = #"{"id":"m1","status":"done","labels":{"me":"Anna","them":"Others","speaker":"Speaker"}}"#
        XCTAssertEqual(MeetingInfo.decode(Data(json.utf8))?.ownerLabel, "Anna")
        XCTAssertNil(MeetingInfo.decode(Data(#"{"id":"m1","status":"done"}"#.utf8))?.ownerLabel)
    }
}
