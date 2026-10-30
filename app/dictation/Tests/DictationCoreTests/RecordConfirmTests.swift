import Foundation
import XCTest
@testable import DictationCore

/// #342.1 + #348(b): "Record" on a call prompt that may have outlived its call asks first instead of
/// recording silence; #340.2: the voices Try Again that would remake names and notes asks first.
final class RecordConfirmTests: XCTestCase {
    private struct FakeRunner: AppleScriptRunner {
        var outcome: ScriptOutcome
        func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome { outcome }
    }

    /// The table: a stale offer asks for any holder; a fresh one records when some browser tab is a call
    /// page, and for a native holder outright; every "cannot tell" asks.
    /// Mutation: RecordCheck.decide, count `.unknown` like `.callPage` -> RED (an unreadable read records silently).
    func testTheRecordCheckAsksOnAnythingItCannotConfirm() {
        for holder in [RecordCheck.Holder.native, .browser] {
            for tabs in [RecordCheck.Tabs.callPage, .noCallPage, .unknown] {
                XCTAssertEqual(RecordCheck.decide(offerStale: true, holder: holder, tabs: tabs), .ask,
                               "stale offer, holder \(holder), tabs \(tabs)")
            }
        }
        XCTAssertEqual(RecordCheck.decide(offerStale: false, holder: .native, tabs: .unknown), .record)
        XCTAssertEqual(RecordCheck.decide(offerStale: false, holder: .browser, tabs: .callPage), .record)
        XCTAssertEqual(RecordCheck.decide(offerStale: false, holder: .browser, tabs: .noCallPage), .ask)
        XCTAssertEqual(RecordCheck.decide(offerStale: false, holder: .browser, tabs: .unknown), .ask)
    }

    /// The staleness peek is the poll's own question, without consuming its state: `absentSince` moves
    /// only in `verdict`, so the press sees what the next poll would see.
    /// Mutation: OfferLifetime.stale, `>= Self.callGoneAfter` -> `>= 0` -> RED.
    func testTheStalenessPeekMirrorsTheVerdict() {
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        var life = OfferLifetime()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = life.verdict(now: t0, offer: offer, liveSource: "meet", users: [])
        XCTAssertFalse(life.stale(now: t0.addingTimeInterval(1), offer: offer, liveSource: "meet"), "the call is live")
        // The absence clock started at t0+2; a press before callGoneAfter is not stale.
        _ = life.verdict(now: t0.addingTimeInterval(2), offer: offer, liveSource: nil, users: [])
        XCTAssertFalse(life.stale(now: t0.addingTimeInterval(3), offer: offer, liveSource: nil))
        XCTAssertTrue(life.stale(now: t0.addingTimeInterval(2 + OfferLifetime.callGoneAfter), offer: offer, liveSource: nil),
                      "gone as long as the prompt may stay up")
        XCTAssertTrue(life.stale(now: t0.addingTimeInterval(3), offer: offer, liveSource: "zoom"),
                      "another call took over")
        XCTAssertFalse(life.stale(now: t0, offer: .browserConsent(browser: "com.google.Chrome"), liveSource: nil),
                       "only a .prompt offer is stale for this question")
    }

    /// The read maps straight to the check's three cases.
    /// Mutation: BrowserTabURLs.read, `.denied, .timedOut, .failed` -> `.callPage` -> RED.
    func testTheAllTabReadAnswersTheThreeCases() {
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet",
                                           runner: FakeRunner(outcome: .value("https://meet.google.com/abc-defg-hij\nhttps://example.com"))),
                       .callPage)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet",
                                           runner: FakeRunner(outcome: .value("https://example.com\nhttps://news.ycombinator.com"))),
                       .noCallPage)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet", runner: FakeRunner(outcome: .value(""))), .noCallPage)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet", runner: FakeRunner(outcome: .denied)), .unknown)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet", runner: FakeRunner(outcome: .timedOut)), .unknown)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet", runner: FakeRunner(outcome: .failed(1))), .unknown)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "a b\" quit", source: "meet",
                                           runner: FakeRunner(outcome: .value("https://meet.google.com/abc-defg-hij"))),
                       .unknown, "a bundle id that is not one never reaches the runner")
    }

    /// A leftover tab of another kind must not vouch for this call: Meet open, Zoom-web prompt -> no call page.
    /// Mutation: BrowserTabURLs.read, `found == source` -> `true` -> RED.
    func testOnlyATabOfThePromptsOwnKindVouchesForTheCall() {
        let tabs = FakeRunner(outcome: .value("https://meet.google.com/abc-defg-hij\nhttps://example.com"))
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "zoom", runner: tabs), .noCallPage)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "meet", runner: tabs), .callPage)
        XCTAssertEqual(BrowserTabURLs.read(bundleID: "com.google.Chrome", source: "", runner: tabs), .callPage,
                       "a prompt with no source accepts any call page")
    }

    /// The Record press's outcome table: only a Cancel the user pressed stops the start, and Record never
    /// cancels. A verdict of `.record` never asks.
    /// Mutation: RecordPrompt.outcome, swap the `.record?` / `.cancel?` results -> RED; drop the `(.ask, nil)` row -> RED.
    func testTheRecordOutcomeTable() {
        XCTAssertEqual(RecordPrompt.outcome(verdict: .record, answer: nil), .start)
        XCTAssertEqual(RecordPrompt.outcome(verdict: .record, answer: .cancel), .start)
        XCTAssertEqual(RecordPrompt.outcome(verdict: .ask, answer: nil), .ask)
        XCTAssertEqual(RecordPrompt.outcome(verdict: .ask, answer: .record), .start, "Record on the question records")
        XCTAssertEqual(RecordPrompt.outcome(verdict: .ask, answer: .cancel), .backToPrompt, "Cancel does not record")
    }

    /// A browser holder gets its tabs re-read; everything else is native.
    /// Mutation: RecordPrompt.holder, drop the browsers lookup (always .native) -> RED.
    func testTheHolderKindFollowsTheBrowserList() {
        XCTAssertEqual(RecordPrompt.holder(bundleID: "com.google.Chrome"), .browser)
        XCTAssertEqual(RecordPrompt.holder(bundleID: "com.brave.Browser"), .browser)
        XCTAssertEqual(RecordPrompt.holder(bundleID: "us.zoom.xos"), .native)
        XCTAssertEqual(RecordPrompt.holder(bundleID: nil), .native)
    }

    /// The voices retry goes on when nothing needs asking, or when the user confirmed; Cancel stops it.
    /// Mutation: VoicesRetry.proceeds, `asks ? confirmed() : true` -> `asks ? !confirmed() : true` -> RED.
    func testTheVoicesRetryProceedsOnlyWhenNotAskedOrConfirmed() {
        var raised = 0
        XCTAssertTrue(VoicesRetry.proceeds(asks: false, confirmed: { raised += 1; return false }))
        XCTAssertEqual(raised, 0, "no question when nothing is remade")
        XCTAssertTrue(VoicesRetry.proceeds(asks: true, confirmed: { true }))
        XCTAssertFalse(VoicesRetry.proceeds(asks: true, confirmed: { false }))
    }

    /// A start that did not record must not leave the question's disabled buttons over the call -- but only the
    /// question its own press showed: an unrelated start (auto, menu, hotkey) that fails leaves a live question up (#374.1).
    /// Mutation: StartBadge.afterAttempt, `!started` -> `false` -> RED.
    /// Mutation: StartBadge.afterAttempt, drop the `question == pressedSource` guard -> RED.
    /// Mutation: MeetingController.start, `pressed: offered ? source : nil` -> `pressed: source` -> RED (wiring pin).
    func testAFailedStartTakesTheQuestionDown() {
        XCTAssertEqual(StartBadge.afterAttempt(started: false, questionSource: "zoom", pressedSource: "zoom"), .hide)
        XCTAssertEqual(StartBadge.afterAttempt(started: true, questionSource: "zoom", pressedSource: "zoom"), .keep)
        XCTAssertEqual(StartBadge.afterAttempt(started: false, questionSource: nil, pressedSource: "zoom"), .keep,
                       "a recording badge or another prompt is never touched")
    }

    /// An unrelated failed start leaves the question of another press up.
    func testAnUnrelatedFailedStartLeavesTheQuestionUp() {
        XCTAssertEqual(StartBadge.afterAttempt(started: false, questionSource: "zoom", pressedSource: nil), .keep,
                       "a start that was not the question's press")
        XCTAssertEqual(StartBadge.afterAttempt(started: false, questionSource: "zoom", pressedSource: "teams"), .keep,
                       "the press of another call's prompt")
    }

    /// What the badge shows when the read returns, as `RecordResume.Badge` (#374.2): the press's own checking state is
    /// `.checkingThis`, another call's is `.other`.
    /// Mutation: RecordResume.badge, invert `shown == source` (`checking(let shown)` -> `shown != source`) -> RED.
    func testTheBadgeStateIsMappedForThisPress() {
        XCTAssertEqual(RecordResume.badge(shown: .checking(source: "zoom"), pressed: "zoom"), .checkingThis)
        XCTAssertEqual(RecordResume.badge(shown: .checking(source: "teams"), pressed: "zoom"), .other)
        XCTAssertEqual(RecordResume.badge(shown: .nothing, pressed: "zoom"), .empty)
        XCTAssertEqual(RecordResume.badge(shown: .other, pressed: "zoom"), .other)
    }

    /// The read returns up to ~1.5 s later: a running recording's badge is left alone, another prompt is not
    /// overwritten (the press still starts), the press's own checking state or an empty badge applies.
    /// Mutation: RecordResume.decide, drop the `recordingOrStarting` line -> RED; `.other` -> `.apply` -> RED.
    func testTheResumedReadRespectsWhatTheBadgeBecame() {
        XCTAssertEqual(RecordResume.decide(recordingOrStarting: true, badge: .checkingThis), .nothing)
        XCTAssertEqual(RecordResume.decide(recordingOrStarting: true, badge: .other), .nothing)
        XCTAssertEqual(RecordResume.decide(recordingOrStarting: false, badge: .checkingThis), .apply)
        XCTAssertEqual(RecordResume.decide(recordingOrStarting: false, badge: .empty), .apply)
        XCTAssertEqual(RecordResume.decide(recordingOrStarting: false, badge: .other), .start)
    }

    /// Every window's every tab is read — the call may be in a background tab; the front tab alone is the
    /// bug this fixes (#348). The browser is never launched, and each window answers or is skipped.
    /// Mutation: BrowserTabURLs.script, `URL of every tab of w` -> `URL of active tab of front window` -> RED.
    func testTheAllTabScriptReadsEveryTabNotJustTheFrontOne() {
        let s = BrowserTabURLs.script(bundleID: "com.brave.Browser") ?? ""
        XCTAssertTrue(s.hasPrefix(#"if application id "com.brave.Browser" is running then"#))
        XCTAssertTrue(s.contains("with timeout of 1 second"))
        XCTAssertTrue(s.contains("repeat with w in windows"))
        XCTAssertTrue(s.contains("URL of every tab of w"))
        XCTAssertFalse(s.contains("active tab"))
        XCTAssertNil(BrowserTabURLs.script(bundleID: "x\"; quit"))
    }

    /// #340.2: Try Again remakes the names and the notes, so it asks when either is there — and a read
    /// that cannot answer asks too. A meeting with neither retries as before.
    /// Mutation: VoicesRetry.asksFirst, `||` -> `&&` -> RED; the final `return` flipped -> RED.
    func testTheVoicesRetryAsksWhenNamesOrNotesExist() {
        func info(notes: String?) -> MeetingInfo { MeetingInfo(id: "m", status: .done, notesMD: notes) }
        let named = SpeakersState(speakers: [SpeakerInfo(id: "them:1", name: "Anna", label: "them:1")])
        let unnamed = SpeakersState(speakers: [SpeakerInfo(id: "them:1", label: "them:1")])
        XCTAssertTrue(VoicesRetry.asksFirst(info: info(notes: "# Stand-up"), speakers: unnamed), "notes alone ask")
        XCTAssertTrue(VoicesRetry.asksFirst(info: info(notes: nil), speakers: named), "a typed name alone asks")
        XCTAssertFalse(VoicesRetry.asksFirst(info: info(notes: nil), speakers: unnamed), "nothing to remake: as before")
        XCTAssertTrue(VoicesRetry.asksFirst(info: nil, speakers: nil), "a read that cannot answer asks")
        XCTAssertTrue(VoicesRetry.asksFirst(info: info(notes: nil), speakers: nil), "one missing side asks")
    }
}
