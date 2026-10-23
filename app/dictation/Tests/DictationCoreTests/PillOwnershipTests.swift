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

    /// #214 — the "Speaking…" pill takes the pill exactly the way the install
    /// pill does: only while no dictation runs. The speak hotkey can be pressed
    /// mid-recording, and the synthesis answer can land after a dictation
    /// started — both shows are guarded, or the recording's look is replaced.
    /// Mutation: drop `if controller.state == .idle` around the pill show in
    /// speakRequest -> RED. Mutation: drop the PillOwnership gate before
    /// showPlaying -> RED.
    func testTheSpeakPillIsNotTakenOverARunningDictation() {
        let source = Self.appDelegateSource
        XCTAssertFalse(source.isEmpty, "AppDelegate.swift unreadable — the wiring guard has nothing to check")
        guard let start = source.range(of: "private func speakRequest(_ text: String, voice: String?, language: String? = nil) {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return XCTFail("speakRequest not found") }
        let body = source[start.lowerBound..<end.upperBound]
        guard let idle = body.range(of: "if controller.state == .idle"),
              let pill = body.range(of: "overlay.showWorking()"),
              let owner = body.range(of: "speakPillOwner = overlay.owner") else {
            return XCTFail("speakRequest lost the idle guard, the pill show or the owner capture")
        }
        XCTAssertLessThan(idle.lowerBound, pill.lowerBound,
                          "the Speaking pill is shown without checking the dictation is idle")
        XCTAssertLessThan(pill.lowerBound, owner.lowerBound,
                          "the owner must be the pill that was just shown")
        guard let gate = body.range(of: "PillOwnership.shouldFinish(owner: self.speakPillOwner"),
              let playing = body.range(of: "self.overlay.showPlaying()") else {
            return XCTFail("showPlaying lost its gate — a reply landing mid-dictation takes the pill")
        }
        XCTAssertLessThan(gate.lowerBound, playing.lowerBound,
                          "showPlaying must fire only while our pill still stands and no dictation runs")
    }

    /// Wiring guard: the four async completions that used to call
    /// overlay.finish() unconditionally — the speak error path, the studio
    /// pill, the update check and the install failure — must clear through
    /// finishPill with the owner count their show captured. Reverting any one
    /// of them to a bare overlay.finish() is exactly the defect this guards.
    func testNonDictationPillClearsAreOwnerScoped() {
        let source = Self.appDelegateSource
        XCTAssertFalse(source.isEmpty, "AppDelegate.swift unreadable — the wiring guard has nothing to check")
        for owner in ["speakPillOwner", "studioPillOwner", "updateCheckPillOwner", "installPillOwner"] {
            XCTAssertTrue(source.contains("finishPill(self.\(owner)"),
                          "\(owner): this pill is cleared without PillOwnership — a finish landing mid-dictation hides the dictation pill")
        }
        XCTAssertTrue(source.contains("PillOwnership.shouldFinish(owner: owner"),
                      "finishPill does not consult PillOwnership — the owner scope is decorative")
    }
}
