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
        XCTAssertTrue(body.contains("let plan = draft.savePlan(against: state)"))
        XCTAssertTrue(body.contains("plan.refusedSentence()"))
        XCTAssertTrue(body.contains("try await saveSpeakers(id: id, edits: plan.edits, refused: plan.refusedSentence())"))
        XCTAssertTrue(body.contains("SpeakersSaved.reopens(wasOffer: wasOffer, answer: state)"), "the split re-open survives a partial save")
        XCTAssertFalse(body.contains("host.notify(sentence); return }"), "no second notice after the save")
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
}
