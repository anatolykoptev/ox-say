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

    /// Renaming a speaker in the main window crashed the app: `notify` ends in AppKit (the pill), and the runner
    /// delivered it from whatever executor `send` resumed on. The daemon call and the follow-up resume off the main
    /// thread here (the premise is asserted, so the test cannot pass vacuously); the notice must still land on it.
    /// Mutation: SpeakersSaveRun.save (MeetingSpeakers.swift, the `@MainActor` above `public static func save`),
    /// delete that line -> testASaveNotifiesOnTheMainThreadWhenTheDaemonCallResumesElsewhere RED.
    func testASaveNotifiesOnTheMainThreadWhenTheDaemonCallResumesElsewhere() async throws {
        let log = ThreadLog()
        let plan = SpeakersSavePlan(edits: edits(["them:1": "Anna"]), refused: [])
        _ = try await SpeakersSaveRun.save(
            edits: plan.edits, notSaved: nil,
            send: { _ in
                log.sendOnMain = await Task.detached { Thread.isMainThread }.value
                return SpeakersState(mode: "auto", speakers: [])
            },
            followUp: { _ in
                log.followUpOnMain = await Task.detached { Thread.isMainThread }.value
                return nil
            },
            notify: { _ in log.notifyOnMain.append(Thread.isMainThread) })
        XCTAssertEqual(log.sendOnMain, false, "premise: the daemon call ran off the main thread")
        XCTAssertEqual(log.followUpOnMain, false, "premise: the follow-up ran off the main thread")
        XCTAssertEqual(log.notifyOnMain, [true], "the notice reaches AppKit: it must be delivered on the main thread")
    }

    /// The menu's panel path: nothing to send, the refusal is told synchronously at the start of `run`, which a caller
    /// off the main actor must still deliver on the main thread.
    /// Mutation: SpeakersSaveRun.run (MeetingSpeakers.swift, the `@MainActor` above `public static func run`),
    /// delete that line -> testARefusalNoticeIsDeliveredOnTheMainThread RED.
    func testARefusalNoticeIsDeliveredOnTheMainThread() async throws {
        let log = ThreadLog()
        let plan = SpeakersSavePlan(edits: SpeakerEdits(), refused: [refusedVoice()])
        let state = try await SpeakersSaveRun.run(
            plan: plan,
            send: { _ in XCTFail("nothing to send"); return SpeakersState(mode: "auto", speakers: []) },
            followUp: { _ in nil },
            notify: { _ in log.notifyOnMain.append(Thread.isMainThread) })
        XCTAssertNil(state)
        XCTAssertEqual(log.notifyOnMain, [true])
    }

    /// What the fakes above saw of the threads (written by one save at a time, read after it ends).
    private final class ThreadLog: @unchecked Sendable {
        var sendOnMain: Bool?
        var followUpOnMain: Bool?
        var notifyOnMain: [Bool] = []
    }
}
