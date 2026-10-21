import XCTest
@testable import DictationCore

final class NoticeGateTests: XCTestCase {
    private let unread = NoticeGate.Notice(message: "The text did not paste", kind: .outcome)

    // Journey (F3): the previous dictation's paste lands nowhere and its 3 s
    // cap settles after the user already started the next dictation. The
    // notice must not show (no pill replaced, no beep) until that dictation
    // is idle again, and then it shows once, with its kind intact.
    func testAnUnreadNoticeDuringTheNextDictationWaitsForIdle() {
        var gate = NoticeGate()
        XCTAssertNil(gate.admit(unread, state: .recording), "a notice must not replace the Listening pill")
        XCTAssertNil(gate.release(state: .recording), "still dictating: nothing to show")
        XCTAssertNil(gate.release(state: .transcribing), "still dictating: nothing to show")
        XCTAssertEqual(gate.release(state: .idle), unread, "the dictation ended: the notice appears")
        XCTAssertNil(gate.release(state: .idle), "shown once")
    }

    func testANoticeWhileTranscribingIsHeldToo() {
        var gate = NoticeGate()
        XCTAssertNil(gate.admit(unread, state: .transcribing))
        XCTAssertEqual(gate.pending, unread)
    }

    func testANoticeWhileIdleShowsAtOnceAndKeepsNothing() {
        var gate = NoticeGate()
        XCTAssertEqual(gate.admit(unread, state: .idle), unread)
        XCTAssertNil(gate.pending)
    }

    // The pill shows one message at a time, so the newest held notice wins.
    func testANewerHeldNoticeReplacesTheOlder() {
        var gate = NoticeGate()
        let error = NoticeGate.Notice(message: "Speak failed", kind: .unrelated)
        XCTAssertNil(gate.admit(unread, state: .recording))
        XCTAssertNil(gate.admit(error, state: .recording))
        XCTAssertEqual(gate.release(state: .idle), error)
        XCTAssertNil(gate.release(state: .idle))
    }
}

final class PasteLastGuardTests: XCTestCase {
    private func history(_ texts: String...) -> DictationHistory {
        let h = DictationHistory()
        texts.forEach { h.add($0) }
        return h
    }

    // F4: Paste Last during a transcription would aim the in-flight paste's
    // clipboard and target at an old dictation.
    func testPasteLastIsRefusedWhileADictationRuns() {
        let h = history("older words")
        XCTAssertFalse(RecentDictationsMenu.canPasteLast(history: h, dictation: .recording))
        XCTAssertFalse(RecentDictationsMenu.canPasteLast(history: h, dictation: .transcribing))
    }

    func testPasteLastNeedsAnIdleStateAndAHistory() {
        XCTAssertTrue(RecentDictationsMenu.canPasteLast(history: history("older words"), dictation: .idle))
        XCTAssertFalse(RecentDictationsMenu.canPasteLast(history: DictationHistory(), dictation: .idle))
    }
}

/// AppKit wiring the unit tests cannot reach, gated by reading the sources —
/// the style of `PillOwnershipTests.testNonDictationPillClearsAreOwnerScoped`.
final class NeverLoseWiringTests: XCTestCase {
    private static func source(_ file: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/OxSayDictation/\(file)")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    /// The text of the type member that starts at `signature` and runs to the
    /// first closing brace at member indent (4 spaces). Empty when absent.
    private static func body(_ signature: String, in source: String) -> String {
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    private func requireBody(_ signature: String, in file: String) -> String {
        let text = Self.body(signature, in: Self.source(file))
        XCTAssertFalse(text.isEmpty, "\(file): `\(signature)` not found — the wiring guard has nothing to check")
        return text
    }

    // Mutation: pass `onUnread: nil` in PasteOutput.settle -> RED.
    func testPasteOutputPassesTheUnreadCallbackThrough() {
        let settle = requireBody("func settle() {", in: "PasteOutput.swift")
        XCTAssertTrue(settle.contains("onUnread: onPasteUnread"),
                      "PasteOutput.settle drops onPasteUnread — an unread paste would be silent")
    }

    // Mutation: delete the `output.onPasteUnread = ...` line in AppDelegate -> RED.
    func testAppDelegateRaisesTheUnreadNotice() {
        let source = Self.source("AppDelegate.swift")
        XCTAssertTrue(source.contains("output.onPasteUnread = { [weak self] in self?.notice(L10nKey.noticePasteUnread.text, kind: .outcome) }"),
                      "AppDelegate does not turn onPasteUnread into the unread notice")
    }

    // Mutation: drop the `guard let admitted = noticeGate.admit(...)` line in
    // notice(), or feed it `state: .idle` -> RED (the journey: an unread
    // notice must not take the pill or beep mid-dictation).
    func testEveryNoticeGoesThroughTheGateBeforeTheOverlayAndTheBeep() {
        let notice = requireBody("private func notice(", in: "AppDelegate.swift")
        let admit = notice.range(of: "guard let admitted = noticeGate.admit(")
        XCTAssertNotNil(admit, "notice() does not consult NoticeGate")
        XCTAssertTrue(notice.contains("state: controller.state)"), "notice() must gate on the controller's live state")
        for effect in ["overlay.showMessage(", "NSSound.beep()", "statusLine.title ="] {
            guard let at = notice.range(of: effect), let admit else {
                XCTFail("notice() lost `\(effect)` or the gate"); continue
            }
            XCTAssertLessThan(admit.lowerBound, at.lowerBound, "`\(effect)` runs before the gate")
        }
        XCTAssertTrue(notice.contains("admitted.message"), "notice() shows the raw message, not the admitted one")
    }

    // Mutation: delete the release in show(.idle) -> RED (held notices never appear).
    func testIdleReleasesTheHeldNotice() {
        let show = requireBody("private func show(", in: "AppDelegate.swift")
        guard let idle = show.range(of: "case .idle:"), let recording = show.range(of: "case .recording:"),
              let release = show.range(of: "noticeGate.release(state: controller.state)") else {
            return XCTFail("show() does not release the held notice")
        }
        XCTAssertTrue(idle.lowerBound < release.lowerBound && release.lowerBound < recording.lowerBound,
                      "the release must sit in the .idle case")
    }

    // Mutation: delete the canPasteLast guard in pasteLastDictation, or put the
    // `output.target = ...` assignment back -> RED.
    func testPasteLastIsGuardedAndNeverReassignsTheSharedTarget() {
        let handler = requireBody("@objc private func pasteLastDictation() {", in: "AppDelegate.swift")
        XCTAssertTrue(handler.contains("RecentDictationsMenu.canPasteLast(history: controller.history, dictation: controller.state)"),
                      "Paste Last runs while a dictation does")
        XCTAssertTrue(handler.contains("output.deliver(text, to:"), "Paste Last must pass its target explicitly")
        XCTAssertFalse(handler.contains("output.target"), "Paste Last reassigns the in-flight dictation's paste target")
    }

    // Mutation: make refreshPasteLastItem ignore the state -> RED; stop
    // refreshing it from show() -> RED.
    func testPasteLastRowFollowsTheDictationState() {
        let refresh = requireBody("private func refreshPasteLastItem() {", in: "AppDelegate.swift")
        XCTAssertTrue(refresh.contains("canPasteLast(history: controller.history, dictation: controller.state)"))
        let show = requireBody("private func show(", in: "AppDelegate.swift")
        XCTAssertTrue(show.contains("refreshPasteLastItem()"), "the row is not re-evaluated when the state changes")
    }
}
