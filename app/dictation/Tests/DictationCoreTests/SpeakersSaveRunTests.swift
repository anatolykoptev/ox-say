import Foundation
import XCTest
@testable import DictationCore

/// #384.1: the menu's speakers save decides in DictationCore, with the side effects as closures; these drive it with
/// recording fakes (the source-text pins used to be the only guard that a save notifies once).
final class SpeakersSaveRunTests: XCTestCase {
    private final class Fakes {
        var sent: [SpeakerEdits] = []
        var notices: [String] = []
        var followUps = 0
        var answer = SpeakersState(mode: "auto", speakers: [])
        var exportSentence: String?
        var failure: Error?
    }

    private func run(_ plan: SpeakersSavePlan, _ f: Fakes) async throws -> SpeakersState? {
        try await SpeakersSaveRun.run(plan: plan,
                                      send: { edits in f.sent.append(edits); if let e = f.failure { throw e }; return f.answer },
                                      followUp: { _ in f.followUps += 1; return f.exportSentence },
                                      notify: { f.notices.append($0) })
    }

    private func edits(_ rename: [String: String]) -> SpeakerEdits {
        var e = SpeakerEdits()
        e.rename = rename
        return e
    }

    private func refusedVoice() -> SpeakerInfo { SpeakerInfo(id: "them:2", label: "Speaker 2") }

    /// A partial save (one name sent, one refused) says ONE thing: the save's own notice with the refusal appended.
    /// Mutation: SpeakersSaveRun.save, call `notify(...)` twice -> RED.
    func testAPartialSaveNotifiesOnce() async throws {
        let f = Fakes()
        let plan = SpeakersSavePlan(edits: edits(["them:1": "Anna"]), refused: [refusedVoice()])
        let state = try await run(plan, f)
        XCTAssertNotNil(state)
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertEqual(f.notices.count, 1, "one notice per save: a second banner buries the first")
        XCTAssertTrue(f.notices.first?.hasSuffix(plan.notSavedSentence() ?? "?") ?? false, "the refusal rides on the save's notice")
        XCTAssertEqual(f.followUps, 1)
    }

    /// Everything refused: nothing is sent and the refusal is the one notice.
    /// Mutation: SpeakersSaveRun.run, drop the `notify` of the empty-edits branch -> RED.
    func testAllRefusedSendsNothingAndNotifiesOnce() async throws {
        let f = Fakes()
        let plan = SpeakersSavePlan(edits: SpeakerEdits(), refused: [refusedVoice()])
        let state = try await run(plan, f)
        XCTAssertNil(state)
        XCTAssertTrue(f.sent.isEmpty, "an empty edit is never sent")
        XCTAssertEqual(f.notices.count, 1)
        XCTAssertEqual(f.followUps, 0)
    }

    /// Nothing to save and nothing refused: silent, nothing sent.
    func testNothingToSaveIsSilent() async throws {
        let f = Fakes()
        let state = try await run(SpeakersSavePlan(edits: SpeakerEdits(), refused: []), f)
        XCTAssertNil(state)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.notices.isEmpty)
    }

    /// A clean save: one notice, the daemon's answer returned.
    func testACleanSaveNotifiesOnceAndReturnsTheAnswer() async throws {
        let f = Fakes()
        f.answer = SpeakersState(mode: "auto", speakers: [], notesQueued: true)
        let state = try await run(SpeakersSavePlan(edits: edits(["them:1": "Anna"]), refused: []), f)
        XCTAssertEqual(state, f.answer)
        XCTAssertEqual(f.notices.count, 1)
    }

    /// The export sentence stands in for "names saved" (one notice still).
    func testTheExportSentenceIsTheNotice() async throws {
        let f = Fakes()
        f.exportSentence = "copy left alone"
        _ = try await run(SpeakersSavePlan(edits: edits(["them:1": "Anna"]), refused: []), f)
        XCTAssertEqual(f.notices, ["copy left alone"])
    }

    /// A daemon failure throws to the caller (which says it once); the save itself notifies nothing.
    func testAFailedSendNotifiesNothingAndThrows() async {
        struct Boom: Error {}
        let f = Fakes()
        f.failure = Boom()
        do {
            _ = try await run(SpeakersSavePlan(edits: edits(["them:1": "Anna"]), refused: [refusedVoice()]), f)
            XCTFail("must throw")
        } catch {}
        XCTAssertTrue(f.notices.isEmpty, "the caller's catch says the failure; no second notice from here")
        XCTAssertEqual(f.followUps, 0)
    }
}
