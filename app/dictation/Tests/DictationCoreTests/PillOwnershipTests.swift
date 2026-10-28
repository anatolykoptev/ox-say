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
              let pill = body.range(of: "overlay.showWorking()"),
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
        for slot in ["handshakePill", "speakPill", "studioPill", "updateCheckPill", "installPill"] {
            XCTAssertTrue(source.contains("beginPill(&\(slot))") || source.contains("beginPill(&self.\(slot))"),
                          "\(slot) is never begun")
            XCTAssertTrue(source.contains("endPill(&\(slot))") || source.contains("endPill(&self.\(slot))"),
                          "\(slot) is never ended through endPill")
        }
        XCTAssertEqual(source.components(separatedBy: ".end(current:").count - 1, 1,
                       "PillSlot.end must be consulted by endPill alone")
        XCTAssertEqual(source.components(separatedBy: "overlay.finish()").count - 1, 2,
                       "a bare overlay.finish() outside endPill and the dictation's idle hide skips the owner scope")
        let idle = Self.appBody("private func show(_ state: DictationState) {")
        XCTAssertTrue(idle.contains("overlay.finish()"), "the dictation's own idle hide moved")
        let end = Self.appBody("private func endPill(_ slot: inout PillSlot) {")
        XCTAssertTrue(end.contains("overlay.finish()") && end.contains("showListening()") && end.contains("showWorking()"),
                      "endPill must finish, or put the dictation look back")
    }

    /// The overlay asks the controller whether a dictation runs before any
    /// hide may take the pill; losing this wiring turns every guard off.
    func testTheOverlayIsToldWhereTheDictationStateLives() {
        XCTAssertTrue(Self.appDelegateSource.contains("overlay.dictationState = { [weak self] in self?.controller?.state ?? .idle }"))
    }

    /// #191.3 — hide() asks about the dictation BEFORE it wipes the live text,
    /// so a hide that is refused mid-dictation does not blank the words.
    /// Mutation: move `liveText.stringValue = ""` above the dictationState
    /// guard in Overlay.hide -> RED.
    func testHideChecksTheDictationBeforeWipingLiveText() {
        let body = Self.overlayBody("private func hide() {")
        guard let guardAt = body.range(of: "dictationState?()"),
              let wipe = body.range(of: "liveText.stringValue = \"\"") else {
            return XCTFail("hide() lost the dictation guard or the live-text wipe")
        }
        XCTAssertLessThan(guardAt.lowerBound, wipe.lowerBound, "live text is wiped before the dictation guard")
    }

    /// #191.4 — resize() leaves the layout of the children to autoresizing: the
    /// window animates to the new frame, and a child placed for the target size
    /// at once (the esc hint) sits outside the shrinking-or-growing window.
    /// Mutation: re-add `hint.frame.origin = ...size.width...` in Overlay.resize -> RED.
    func testResizeDoesNotLayChildrenOutForTheTargetSize() {
        let body = Self.overlayBody("private func resize(to newSize: NSSize, animated: Bool = false) {")
        XCTAssertFalse(body.contains("hint.frame.origin"), "the esc hint is placed for the target size while the window animates")
        XCTAssertFalse(body.contains("background.frame ="), "the background is laid out for the target size while the window animates")
    }

    /// #191.7 — the visibility check does not log a fault for a pill that
    /// cannot be on screen (display asleep, screen locked).
    /// Mutation: move the PillVisibility guard below the fault log in
    /// Overlay.checkVisible -> RED.
    func testTheVisibilityCheckSkipsWhenTheScreenIsLocked() {
        let body = Self.overlayBody("private func checkVisible(expected: Int, owner ownerAtShow: Int, healed: Bool) {")
        guard let skip = body.range(of: "PillVisibility.expectsOnscreen"),
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
}
