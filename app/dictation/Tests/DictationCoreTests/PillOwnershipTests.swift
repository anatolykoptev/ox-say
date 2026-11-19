import XCTest
@testable import DictationCore

final class PillOwnershipTests: XCTestCase {
    /// The AppDelegate source the wiring guard reads — the overlay itself is
    /// AppKit and cannot run under swift test, so the guard asserts each of the
    /// four async completions that used to clear the pill unconditionally now
    /// goes through the owner scope.
    private static var appDelegateSource: String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    /// A task whose pill is still the current owner asks to clear it while a
    /// dictation is recording or transcribing: the finish is refused — the
    /// pill belongs to the dictation until the key is up. This is the journey:
    /// a background update check, a studio task or a speak request completing
    /// while the user is still holding the key must not take the pill away.
    func testNonDictationOwnerCannotFinishDuringRecording() {
        XCTAssertFalse(PillOwnership.shouldFinish(owner: 4, current: 4, dictation: .recording),
                       "an owner-scoped finish must never hide the pill mid-recording")
        XCTAssertFalse(PillOwnership.shouldFinish(owner: 4, current: 4, dictation: .transcribing),
                       "an owner-scoped finish must never hide the pill mid-transcription")
    }

    /// The pill's current owner clears it once nothing dictates: the ordinary
    /// "task done, pill down" path.
    func testCurrentOwnerFinishesWhileIdle() {
        XCTAssertTrue(PillOwnership.shouldFinish(owner: 4, current: 4, dictation: .idle))
    }

    /// Another owner took the pill since (a dictation, a message, a speak):
    /// the late finish belongs to a stale pill and must not hide the new one.
    func testStaleOwnerNeverFinishes() {
        XCTAssertFalse(PillOwnership.shouldFinish(owner: 4, current: 5, dictation: .idle))
        XCTAssertFalse(PillOwnership.shouldFinish(owner: nil, current: 4, dictation: .idle),
                       "a task that never showed a pill has nothing to finish")
    }

    private static func appBody(_ signature: String) -> String {
        let source = appDelegateSource
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("\(signature) not found in AppDelegate.swift"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    private static func overlayBody(_ signature: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/Overlay.swift")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("\(signature) not found in Overlay.swift"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// #214 — the "Speaking…" pill takes the pill exactly the way the install
    /// pill does: only while no dictation runs. The speak hotkey can be pressed
    /// mid-recording, and the synthesis answer can land after a dictation
    /// started — both shows are guarded, or the recording's look is replaced.
    /// Mutation: drop `if controller.state == .idle` around the pill show in
    /// speakRequest -> RED. Mutation: drop the slot gate before showPlaying -> RED.
    func testTheSpeakPillIsNotTakenOverARunningDictation() {
        let body = Self.appBody("private func speakRequest(_ text: String, voice: String?, language: String? = nil) {")
        guard let idle = body.range(of: "if controller.state == .idle"),
              let pill = body.range(of: "overlay.showWorking(owner: .task)"),
              let begin = body.range(of: "beginPill(&speakPill)") else {
            return XCTFail("speakRequest lost the idle guard, the pill show or the slot begin")
        }
        XCTAssertLessThan(idle.lowerBound, pill.lowerBound,
                          "the Speaking pill is shown without checking the dictation is idle")
        XCTAssertLessThan(pill.lowerBound, begin.lowerBound,
                          "the slot must begin on the pill that was just shown")
        guard let gate = body.range(of: "speakPill.stillOurs(current: self.overlay.owner"),
              let playing = body.range(of: "self.overlay.showPlaying()") else {
            return XCTFail("showPlaying lost its gate — a reply landing mid-dictation takes the pill")
        }
        XCTAssertLessThan(gate.lowerBound, playing.lowerBound,
                          "showPlaying must fire only while our pill still stands and no dictation runs")
    }

    /// #191.1 — every pill a task puts up goes through ONE begin/end pair
    /// (the PillSlot behaviour is tested in PillSlotTests). Here the wiring:
    /// each slot is begun and ended through the helpers, the helpers are the
    /// only callers of PillSlot.end, and the only bare `overlay.finish()`
    /// calls are the helper's own and the dictation's own idle hide. The
    /// owner-less shortcuts the old substring scan accepted are gone.
    /// Mutation: replace `endPill(&speakPill)` in speakRequest with
    /// `overlay.finish()` -> RED (bare finish count).
    func testEveryTaskPillGoesThroughTheBeginEndHelpers() {
        let source = Self.appDelegateSource
        XCTAssertFalse(source.isEmpty, "AppDelegate.swift unreadable — the wiring guard has nothing to check")
        for slot in ["handshakePill", "speakPill", "updateCheckPill", "installPill"] {
            XCTAssertTrue(source.contains("beginPill(&\(slot))") || source.contains("beginPill(&self.\(slot))"),
                          "\(slot) is never begun")
            XCTAssertTrue(source.contains("endPill(&\(slot))") || source.contains("endPill(&self.\(slot))"),
                          "\(slot) is never ended through endPill")
        }
        // #191.6 — Studio tasks have one slot each (TaskPills): shown and ended through their own helpers,
        // the end handing the task's slot to the common endPill.
        // Mutation: back to a single `PillSlot` shared by every task -> RED (TaskPillsTests).
        XCTAssertTrue(source.contains("studioPills.begin(task: task"), "studioPills is never begun")
        let studioEnd = Self.appBody("private func endStudioPill(task: String) {")
        XCTAssertTrue(studioEnd.contains("studioPills.end(task: task") && studioEnd.contains("endPill(&slot)"),
                      "a Studio task's end must go through its own slot and the common endPill")
        XCTAssertEqual(source.components(separatedBy: ".end(current:").count - 1, 1,
                       "PillSlot.end must be consulted by endPill alone")
        XCTAssertEqual(source.components(separatedBy: "overlay.finish()").count - 1, 2,
                       "a bare overlay.finish() outside endPill and the dictation's idle hide skips the owner scope")
        let idle = Self.appBody("private func show(_ state: DictationState) {")
        XCTAssertTrue(idle.contains("overlay.finish()"), "the dictation's own idle hide moved")
        let end = Self.appBody("private func endPill(_ slot: inout PillSlot) {")
        XCTAssertTrue(end.contains("overlay.finish()") && end.contains("showListening(owner: .dictation)") && end.contains("showWorking(owner: .dictation)"),
                      "endPill must finish, or put the dictation look back")
        // The restored "Transcribing…" label gets its elapsed seconds back at
        // once, not at the next one-second tick. Mutation: drop the tickWorking()
        // call after showWorking() in endPill -> RED.
        XCTAssertTrue(end.contains("showWorking(owner: .dictation)\n            tickWorking()"),
                      "the restored working label waits a tick for its seconds")
    }

    /// #306.2/.3 — the skipped check is remembered and re-armed on unlock/wake, and the asleep test looks at the
    /// display the panel is on, not the main one.
    /// Mutation: restore `CGMainDisplayID()` in checkVisible's asleep test, or drop the `recheck.skipped(show:` call -> RED.
    func testTheSkippedCheckIsRearmedAndTheAsleepTestUsesThePanelsDisplay() {
        let check = Self.overlayBody("private func checkVisible(expected: Int, owner ownerAtShow: Int) {")
        XCTAssertTrue(check.contains("PlateProbe.expectsOnscreen(panel)"), "the lock/asleep guard stays in front of the check")
        let probe = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OxSayDictation/PlateProbe.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(probe.contains("CGDisplayIsAsleep(display)") && probe.contains("panel.screen?.deviceDescription"),
                      "the asleep test must look at the panel's display")
        XCTAssertTrue(check.contains("recheck.skipped(show: expected)"), "a skipped check is not remembered")
        let back = Self.overlayBody("private func screenCameBack() {")
        XCTAssertTrue(back.contains("recheck.resume(show: expected, wantsVisible: wantsVisible)") && back.contains("checkVisible("),
                      "the unlock/wake must run the remembered check")
        let source = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OxSayDictation/Overlay.swift"), encoding: .utf8)) ?? ""
        XCTAssertTrue(source.contains("screensDidWakeNotification") && source.contains("com.apple.screenIsUnlocked"),
                      "the overlay no longer listens for the unlock and the display wake")
    }

    /// The overlay asks the controller whether a dictation runs before any
    /// hide may take the pill; losing this wiring turns every guard off.
    func testTheOverlayIsToldWhereTheDictationStateLives() {
        XCTAssertTrue(Self.appDelegateSource.contains("overlay.dictationState = { [weak self] in self?.controller?.state ?? .idle }"))
    }

    /// #191.3 — hide() asks about the dictation BEFORE it wipes the live text,
    /// and the refused branch (up to its `return`) touches no live text at all:
    /// a hide refused mid-dictation must not blank the words.
    /// Mutation: insert `liveText.stringValue = ""` inside the dictation
    /// branch of Overlay.hide, or above the guard -> RED.
    func testHideChecksTheDictationBeforeWipingLiveText() {
        let body = Self.overlayBody("private func hide() {")
        guard let guardAt = body.range(of: "dictationState?()"),
              let ret = body.range(of: "return\n", range: guardAt.upperBound..<body.endIndex) else {
            return XCTFail("hide() lost the dictation guard or its return")
        }
        let upToReturn = body[body.startIndex..<ret.upperBound]
        XCTAssertFalse(upToReturn.contains("liveText.stringValue"),
                       "live text is assigned before the dictation branch returns")
        XCTAssertFalse(upToReturn.contains("liveText.isHidden"),
                       "live text is hidden before the dictation branch returns")
        XCTAssertTrue(body[ret.upperBound...].contains("liveText.stringValue = \"\""),
                      "the ordinary hide no longer clears the live text")
    }

    /// #191.4 — resize() assigns no frame computed from the target size to any
    /// view; the only frame it sets is the panel's own, which animates. A view
    /// placed for newSize at once sits outside the still-small window.
    /// Mutation: add any `<view>.frame... = ` / `setFrameOrigin` / `setFrameSize`
    /// line to Overlay.resize -> RED.
    func testResizeDoesNotLayChildrenOutForTheTargetSize() throws {
        let body = Self.overlayBody("private func resize(to newSize: NSSize, animated: Bool = false) {")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let assignment = try NSRegularExpression(pattern: #"\.frame(\.(origin|size)(\.\w+)?)?\s*=(?!=)"#)
        let range = NSRange(body.startIndex..., in: body)
        XCTAssertEqual(assignment.numberOfMatches(in: body, range: range), 0,
                       "a view frame is assigned inside resize()")
        XCTAssertFalse(body.contains("setFrameOrigin") || body.contains("setFrameSize"))
        let setFrames = body.components(separatedBy: "setFrame(").count - 1
        let panelSetFrames = body.components(separatedBy: "panel.animator().setFrame(").count - 1
            + body.components(separatedBy: "panel.setFrame(").count - 1
        XCTAssertEqual(setFrames, panelSetFrames, "setFrame on something other than the panel")
    }

    /// #191.5 — a snap resize while an animated one is in flight must end at the snap's width. AppKit's window animator
    /// keeps driving the frame to its own target after a plain setFrame, so a snap goes through the animator too, with
    /// the zero duration Core names, which replaces the grow; the plain setFrame follows it, never leads.
    /// That AppKit really leaves the stale width needs a live window: see the issue's stress step.
    /// Mutations (call site): Overlay.resize, `context.duration = PillTiming.resizeSeconds(animated: animated)` ->
    /// `context.duration = 0.15` -> RED; wrap the animator call in `if animated {` (the old split) -> RED; move the
    /// plain `panel.setFrame(` above the group -> RED.
    func testASnapResizeGoesThroughTheAnimatorToo() throws {
        XCTAssertEqual(PillTiming.resizeSeconds(animated: true), 0.15)
        XCTAssertEqual(PillTiming.resizeSeconds(animated: false), 0)
        let body = Self.overlayBody("private func resize(to newSize: NSSize, animated: Bool = false) {")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(body.contains("context.duration = PillTiming.resizeSeconds(animated: animated)"))
        XCTAssertFalse(body.contains("if animated {"), "the animator must not be reserved for the animated resize")
        let animator = try XCTUnwrap(body.range(of: "panel.animator().setFrame(frame, display: true)"))
        let plain = try XCTUnwrap(body.range(of: "if !animated { panel.setFrame(frame, display: true) }"))
        XCTAssertLessThan(animator.lowerBound, plain.lowerBound, "the plain setFrame leads the animator")
        XCTAssertEqual(body.components(separatedBy: "panel.setFrame(").count - 1, 1)
    }

    /// #191.7 — the visibility check does not log a fault for a pill that
    /// cannot be on screen (display asleep, screen locked).
    /// Mutation: move the PillVisibility guard below the fault log in
    /// Overlay.checkVisible -> RED.
    func testTheVisibilityCheckSkipsWhenTheScreenIsLocked() {
        let body = Self.overlayBody("private func checkVisible(expected: Int, owner ownerAtShow: Int) {")
        guard let skip = body.range(of: "PlateProbe.expectsOnscreen"),
              let fault = body.range(of: ".fault(") else {
            return XCTFail("checkVisible lost the screen-state guard or the fault log")
        }
        XCTAssertLessThan(skip.lowerBound, fault.lowerBound)
    }

    /// #293.2 — a message hides after a time that scales with its length.
    /// Mutation: restore the flat `.now() + 4` in Overlay.showMessage -> RED.
    func testAMessageHidesAfterTheScaledDelay() {
        let body = Self.overlayBody("func showMessage(_ text: String) {")
        XCTAssertTrue(body.contains("PillTiming.messageSeconds(characters: text.count)"))
        XCTAssertFalse(body.contains(".now() + 4"))
    }

    /// A streaming reply that lands once the dictation is over, or while no dictation owns the pill, is dropped.
    /// Mutation: PillOwnership.acceptsLiveText, return `true` -> RED.
    func testLiveTextIsAcceptedOnlyWhileADictationRuns() {
        XCTAssertTrue(PillOwnership.acceptsLiveText(dictation: .recording))
        XCTAssertTrue(PillOwnership.acceptsLiveText(dictation: .transcribing))
        XCTAssertFalse(PillOwnership.acceptsLiveText(dictation: .idle))
    }

    /// Mutation: PillOwnership.mayShowPlayback, return `true` -> RED.
    func testPlaybackLooksOnlyTakeTheIdlePill() {
        XCTAssertTrue(PillOwnership.mayShowPlayback(dictation: .idle))
        XCTAssertFalse(PillOwnership.mayShowPlayback(dictation: .recording))
        XCTAssertFalse(PillOwnership.mayShowPlayback(dictation: .transcribing))
    }

    /// «Показывать пилюлю при диктовке» off orders out only the dictation's
    /// own shows. The owner is declared at the call site — a task's borrowed
    /// working look (studio, update check, install, handshake, "Speaking…")
    /// orders in even while a dictation runs, and a message or playback is
    /// never gated at all.
    /// Mutations (PillOwnership.order): `owner == .dictation` -> `owner != .dictation`
    /// -> RED; `!pillShown` -> `pillShown` -> RED; gating `.task` too -> RED.
    func testTheGateOrdersOutOnlyTheDictationsOwnShows() {
        XCTAssertEqual(PillOwnership.order(owner: .dictation, pillShown: false), .orderOut,
                       "the dictation's own show with the setting off stays ordered out")
        XCTAssertEqual(PillOwnership.order(owner: .dictation, pillShown: true), .orderIn,
                       "with the setting on the dictation's shows pass as before")
        XCTAssertEqual(PillOwnership.order(owner: .task, pillShown: false), .orderIn,
                       "a task's working show during a dictation still orders in — the owner decides, not the state")
        XCTAssertEqual(PillOwnership.order(owner: .task, pillShown: true), .orderIn)
        XCTAssertEqual(PillOwnership.order(owner: .transient, pillShown: false), .orderIn,
                       "a message (an error!) or playback is never gated")
        XCTAssertEqual(PillOwnership.order(owner: .transient, pillShown: true), .orderIn)
    }

    /// The gate lives in the one show path and every show declares its owner:
    /// `show()` records who asked, asks DictationCore for the verdict and
    /// applies it verbatim — `.orderIn` puts the panel up, anything else
    /// orders it out. Because the branch outcome is a value returned, not a
    /// Bool consumed inline, an inverted call site reads wrong in this test
    /// and a `!` no longer compiles.
    /// Mutations (Overlay.show): `verdict == .orderIn` -> `verdict != .orderIn`
    /// or `== .orderOut` (Codex's `!`, which is now a compile error) -> RED;
    /// `pillOwner = who` dropped -> RED (the toggle and restores lose the
    /// owner); drop `panel.orderOut(nil)` -> RED. Mutations (call sites): a
    /// task pill shown `owner: .dictation` -> RED.
    func testTheGateKnowsWhoAskedForTheShow() {
        let show = Self.overlayBody("private func show(owner who: PillOwner) -> PillOrder {")
        XCTAssertTrue(show.contains("pillOwner = who"), "the show records who asked — the toggle and the restores read it")
        XCTAssertTrue(show.contains("PillOwnership.order(owner: who"), "the gate left the one show path")
        XCTAssertTrue(show.contains("showsDictationPill?()"), "the gate no longer reads the setting live")
        XCTAssertTrue(show.contains("verdict == .orderIn"),
                      "the verdict is applied verbatim — an inverted branch orders the dictation pill out")
        XCTAssertTrue(show.contains("panel.orderOut(nil)"), "a refused show must take the pill down")
        let restore = Self.overlayBody("private func restoreDictationLook(_ look: PillDictationLook) {")
        XCTAssertTrue(restore.contains("showListening(owner: .dictation)") && restore.contains("showWorking(owner: .dictation)"),
                      "the restore is the dictation's own show — it must pass the gate")
        let app = Self.appDelegateSource
        XCTAssertTrue(app.contains("overlay.showsDictationPill = { DictationSettings.showPill(.standard) }"),
                      "the overlay lost its live read of the setting")
        XCTAssertTrue(app.contains("pillShownChanged: { [unowned self] in self.overlay.dictationPillSettingChanged() }"),
                      "flipping the switch no longer reaches the overlay")
        XCTAssertEqual(app.components(separatedBy: "overlay.showListening(owner: .dictation)").count - 1, 2,
                       "the dictation's listening shows (state change and pill restore) must declare their owner")
        XCTAssertEqual(app.components(separatedBy: "overlay.showWorking(owner: .dictation)").count - 1, 2,
                       "the dictation's working shows (state change and pill restore) must declare their owner")
        XCTAssertEqual(app.components(separatedBy: "overlay.showWorking(owner: .task)").count - 1, 5,
                       "install, handshake, studio, update-check and speak pills borrow the look as tasks")
        XCTAssertFalse(app.contains("overlay.showListening()") || app.contains("overlay.showWorking()"),
                       "a show without an owner is gated or freed by accident")
    }

    /// A task pill that is up is not the dictation's: the «Показывать пилюлю»
    /// switch acts on a dictation-owned pill only — it never replaces a task
    /// pill with the dictation look nor takes it down — and a refused hide
    /// restores the dictation look over a dictation or transient pill only.
    /// Mutations (Overlay.dictationPillSettingChanged): drop
    /// `pillOwner == .dictation` -> RED (the switch replaces a task pill);
    /// same in hide() -> RED (a stray hide takes a task pill down then shows
    /// the dictation look over it).
    func testTheToggleAndTheRestoresLeaveATaskPillAlone() {
        let changed = Self.overlayBody("func dictationPillSettingChanged() {")
        XCTAssertTrue(changed.contains("!showingMessage"), "the switch must not kill a message that is up")
        XCTAssertTrue(changed.contains("pillOwner == .dictation"),
                      "the switch acts on a dictation-owned pill only — a task pill stays up and unchanged")
        XCTAssertTrue(changed.contains("restoreDictationLook(look)"),
                      "the switch must put the dictation look back through the gated shows")
        let hide = Self.overlayBody("private func hide() {")
        XCTAssertTrue(hide.contains("pillOwner != .task"),
                      "a refused hide restores over a pill that is not a task's — a task pill is taken down")
        XCTAssertTrue(hide.contains("restoreDictationLook(look)"),
                      "a refused hide restores through the gate, or a hidden pill re-shows")
    }

    /// While the pill is hidden by the setting the dictation's shows still
    /// run — but nothing animates: the bars' 30 Hz timer and the spinner
    /// start only when the show orders in, and they start again when a
    /// restore orders the pill back in.
    /// Mutations: `if show(owner: who) == .orderIn { bars.start() }` -> bare
    /// `show(owner: who)` + `bars.start()` -> RED; same for the spinner -> RED.
    func testASuppressedShowStartsNoAnimation() {
        let listening = Self.overlayBody("func showListening(owner who: PillOwner) {")
        XCTAssertTrue(listening.contains("if show(owner: who) == .orderIn { bars.start() }"),
                      "the bars' timer must start only once the pill is ordered in")
        let working = Self.overlayBody("func showWorking(owner who: PillOwner) {")
        XCTAssertTrue(working.contains("if show(owner: who) == .orderIn { spinner.startAnimation(nil) }"),
                      "the spinner must start only once the pill is ordered in")
    }

    /// The callers decide through those two functions. Mutation: AppDelegate, the streamer's `onText` closure without
    /// the `PillOwnership.acceptsLiveText` guard -> RED; the studio `play` closure's `if showPill && PillOwnership.mayShowPlayback(...)`
    /// back to `if showPill` -> RED.
    func testTheLiveTextAndTheStudioPlaybackPillAreGated() {
        let source = Self.appDelegateSource
        XCTAssertFalse(source.isEmpty)
        XCTAssertTrue(source.contains("streamer.onText = { [weak self] text in\n            guard let self, PillOwnership.acceptsLiveText(dictation: self.controller.state) else { return }\n            self.overlay.setLiveText(text)"))
        XCTAssertFalse(source.contains("overlay.setLiveText(text) }"), "an ungated live-text hand-over is back")
        XCTAssertTrue(source.contains("if showPill && PillOwnership.mayShowPlayback(dictation: self.controller.state) { self.overlay.showPlaying() }"))
        XCTAssertEqual(source.components(separatedBy: "self.overlay.showPlaying()").count - 1, 2, "speak (gated by PillOwnership.shouldFinish) and studio")
    }
}
