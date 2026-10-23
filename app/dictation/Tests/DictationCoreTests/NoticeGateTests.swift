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

    // The pill shows one message at a time: of two notices of equal rank the
    // newest wins.
    func testANewerHeldNoticeOfEqualRankReplacesTheOlder() {
        var gate = NoticeGate()
        let error = NoticeGate.Notice(message: "Speak failed", kind: .unrelated)
        XCTAssertNil(gate.admit(unread, state: .recording))
        XCTAssertNil(gate.admit(error, state: .recording))
        XCTAssertEqual(gate.release(state: .idle), error)
        XCTAssertNil(gate.release(state: .idle))
    }
}

/// #193: which held notice survives, and what the unread-paste notice is tagged.
final class NoticePriorityTests: XCTestCase {
    private let unread = NoticeGate.Notice.unreadPaste("A: the text did not paste")
    private let clipboardOnly = NoticeGate.Notice(message: "B: the text is on the clipboard", kind: .outcome)
    private let transcribeError = NoticeGate.Notice(message: "B: transcription failed", kind: .outcome)
    private let update = NoticeGate.Notice.updateAvailable("A new version", tag: "v0.1.30")

    // F4 — Journey: dictation A's paste is unread; B's deliver raises A's
    // notice (held), then B's own clipboard-only notice or transcription error
    // in the same turn. A's text is only in Recent Dictations: its notice is the
    // costlier one and must be the one shown.
    // Mutation: NoticeGate.admit, delete the `held.priority > notice.priority`
    // guard (newest always replaces) -> RED.
    func testTheCostlierHeldNoticeSurvivesANewerCheaperOne() {
        for newer in [clipboardOnly, transcribeError, update] {
            var gate = NoticeGate()
            XCTAssertNil(gate.admit(unread, state: .recording))
            XCTAssertNil(gate.admit(newer, state: .recording))
            XCTAssertEqual(gate.release(state: .idle), unread, "the lost-text notice was dropped for \(newer.message)")
            XCTAssertNil(gate.release(state: .idle), "shown once")
        }
    }

    func testANewerCostlierNoticeReplacesACheaperHeldOne() {
        var gate = NoticeGate()
        XCTAssertNil(gate.admit(update, state: .recording))
        XCTAssertNil(gate.admit(clipboardOnly, state: .transcribing))
        XCTAssertEqual(gate.release(state: .idle), clipboardOnly)
        XCTAssertNil(gate.admit(clipboardOnly, state: .recording))
        XCTAssertNil(gate.admit(unread, state: .recording))
        XCTAssertEqual(gate.release(state: .idle), unread)
    }

    func testUpdateNoticesRankLowestAndUnreadPasteHighest() {
        XCTAssertTrue(update.priority < clipboardOnly.priority)
        XCTAssertTrue(clipboardOnly.priority < unread.priority)
    }

    // The answer to a click the user just made ranks like any other notice, so
    // a newer one of equal rank does not lose to it silently and it is not the
    // first dropped.
    // Mutation: NoticeGate.Notice.updateRefused, add `priority: .low` -> RED.
    func testTheRefusedClickNoticeRanksNormal() {
        XCTAssertEqual(NoticeGate.Notice.updateRefused("m").priority, .normal)
        XCTAssertEqual(NoticeGate.Notice.updateRefused("m").kind, .unrelated)
    }

    // MAJOR — the lost-text pointer is the user's only way to their text: the
    // reason of a self-ended recording is not flushed over a notice that was just
    // released and shown in the same idle transition (the pill holds one message).
    // Mutation: DictationNotice.reasonToFlush returns `endedReason` always -> RED.
    func testAReleasedNoticeIsNotOverwrittenByTheEndedReasonInTheSameTick() {
        let reason = "Recording stopped at the length cap."
        XCTAssertNil(DictationNotice.reasonToFlush(reason, releasedNotice: true),
                     "the reason replaced the notice that was just shown")
        XCTAssertEqual(DictationNotice.reasonToFlush(reason, releasedNotice: false), reason)
        XCTAssertNil(DictationNotice.reasonToFlush(nil, releasedNotice: false))
    }

    // F3 — the unread notice is about the PREVIOUS dictation: a later
    // dictation's endedReason must not become its prefix.
    // Mutation: NoticeGate.Notice.unreadPaste, `kind: .unrelated` -> `.outcome` -> RED.
    func testTheUnreadNoticeIsNotPrefixedWithALaterDictationsReason() {
        let merged = DictationNotice.merge(endedReason: "Recording stopped at the length cap.",
                                           into: unread.message, kind: unread.kind)
        XCTAssertEqual(merged.message, unread.message, "B's endedReason was attached to a message about A")
        XCTAssertEqual(merged.endedReason, "Recording stopped at the length cap.", "the reason was spent on A's notice")
    }

    // F2 — #198.2: a release counts as told only when its notice was SHOWN.
    // Journey: the notice is raised during a dictation, held, then replaced by a
    // costlier one. It must be raised again by the next check.
    // Mutation: AutoUpdateSchedule.apply, set `state.lastNotifiedVersion = remote`
    // when notify (persist at raise time) -> RED.
    func testAHeldThenDroppedUpdateNoticeIsNotRememberedAsTold() {
        let fetch: Result<(tag: String, url: URL?, body: String), UpdateError> = .success(("v0.1.30", nil, "notes"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = AutoUpdateState()
        var gate = NoticeGate()
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: fetch, local: "0.1.29", now: now, state: &state),
                       .offer(tag: "v0.1.30", notify: true))
        XCTAssertNil(state.lastNotifiedVersion, "told at raise time: a held notice that is dropped is lost for good")
        XCTAssertNil(gate.admit(update, state: .recording))
        XCTAssertNil(gate.admit(unread, state: .recording)) // replaces it
        let shown = gate.release(state: .idle)
        XCTAssertEqual(shown, unread)
        AutoUpdateSchedule.noticeShown(shown!, state: &state)
        XCTAssertNil(state.lastNotifiedVersion, "an unrelated notice was shown; the release was never told")
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: fetch, local: "0.1.29", now: now.addingTimeInterval(86_400), state: &state),
                       .offer(tag: "v0.1.30", notify: true), "the lost notice must be raised again")
    }

    func testAShownUpdateNoticeIsRememberedAsTold() {
        let fetch: Result<(tag: String, url: URL?, body: String), UpdateError> = .success(("v0.1.30", nil, "notes"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = AutoUpdateState()
        var gate = NoticeGate()
        _ = AutoUpdateSchedule.apply(fetch: fetch, local: "0.1.29", now: now, state: &state)
        // Held by a dictation, shown at idle.
        XCTAssertNil(gate.admit(update, state: .transcribing))
        AutoUpdateSchedule.noticeShown(gate.release(state: .idle)!, state: &state)
        XCTAssertEqual(state.lastNotifiedVersion, "v0.1.30")
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: fetch, local: "0.1.29", now: now.addingTimeInterval(86_400), state: &state),
                       .offer(tag: "v0.1.30", notify: false))
        // Shown at once while idle.
        var other = AutoUpdateState()
        _ = AutoUpdateSchedule.apply(fetch: fetch, local: "0.1.29", now: now, state: &other)
        AutoUpdateSchedule.noticeShown(gate.admit(update, state: .idle)!, state: &other)
        XCTAssertEqual(other.lastNotifiedVersion, "v0.1.30")
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

    // Mutation: construct the ClipboardLease before the remote check in
    // PasteOutput.deliver(_:to:) -> RED (the lease's writeText destroys the
    // iPhone copy before the check ever runs).
    func testDeliverChecksRemoteBeforeBorrowingTheClipboard() {
        let body = requireBody("func deliver(_ text: String, to target: pid_t?) -> Delivery {", in: "PasteOutput.swift")
        guard let remote = body.range(of: "holdsRemoteCopy"),
              let lease = body.range(of: "ClipboardLease(") else {
            return XCTFail("deliver(_:to:) must detect a remote clipboard and only then decide how to deliver")
        }
        XCTAssertLessThan(remote.lowerBound, lease.lowerBound,
                          "a ClipboardLease writes the text at init: checking remote after it destroys the copy")
        XCTAssertTrue(body.contains("postTypedText"), "the remote path must type the text, not paste it")
        // Mutation: pass `clipboardRemote: false` (or any value but the
        // holdsRemoteCopy result) to OutputPolicy.decide at the call site -> RED
        // (every paste over an iPhone copy destroys it again).
        let remoteVariable = body.range(of: #"let (\w+) = plain\.holdsRemoteCopy"#, options: .regularExpression)
            .map { String(body[$0]).replacingOccurrences(of: "let ", with: "")
                .components(separatedBy: " ").first ?? "" }
        XCTAssertNotNil(remoteVariable, "deliver(_:to:) must bind `plain.holdsRemoteCopy` to a variable")
        XCTAssertTrue(body.contains("clipboardRemote: \(remoteVariable ?? "?"))"),
                      "OutputPolicy.decide must receive the holdsRemoteCopy result as clipboardRemote:")
        // Mutation: write the text to the clipboard inside `case .typed:` -> RED.
        guard let typedStart = body.range(of: "case .typed:"),
              let typedEnd = body.range(of: "case .paste:", range: typedStart.upperBound..<body.endIndex) else {
            return XCTFail("deliver(_:to:) lost its `.typed` case")
        }
        let typed = body[typedStart.upperBound..<typedEnd.lowerBound]
        XCTAssertFalse(typed.contains("writeText") || typed.contains("ClipboardLease("),
                       "the typed path must leave the clipboard untouched")
    }

    // Mutation: delete the `output.onTypedOverRemoteClipboard = ...` block in
    // AppDelegate, or change its log text -> RED (the typed route would leave
    // no trace in the unified log).
    func testAppDelegateLogsTheTypedRoute() {
        let source = Self.source("AppDelegate.swift")
        XCTAssertTrue(source.contains("output.onTypedOverRemoteClipboard = { chars, seconds in"),
                      "AppDelegate does not log the typed-over-iPhone-copy route")
        XCTAssertTrue(source.contains("clipboard held a Universal Clipboard copy: posted the text as keystrokes, clipboard untouched chars="),
                      "the typed-route log line changed or lost its fields")
        XCTAssertTrue(source.contains("post_ms="), "the log must say post_ms: it is the enqueue time, not delivery")
    }

    // Mutation: delete the `output.onPasteUnread = ...` line in AppDelegate -> RED.
    func testAppDelegateRaisesTheUnreadNotice() {
        let source = Self.source("AppDelegate.swift")
        XCTAssertTrue(source.contains("output.onPasteUnread = { [weak self] in self?.notice(.unreadPaste(L10nKey.noticePasteUnread.text)) }"),
                      "AppDelegate does not turn onPasteUnread into the unread notice")
    }

    // Mutation: drop the `guard let admitted = noticeGate.admit(...)` line in
    // notice(), or feed it `state: .idle` -> RED (the journey: an unread
    // notice must not take the pill or beep mid-dictation).
    func testEveryNoticeGoesThroughTheGateBeforeTheOverlayAndTheBeep() {
        let notice = requireBody("private func notice(_ raised: NoticeGate.Notice) {", in: "AppDelegate.swift")
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

    // F5 — #193.3: the held notice is released BEFORE the endedReason flush. An
    // `.outcome` held notice takes the reason as its prefix and spends it; flushed
    // first, the reason would be said alone and the notice would lose its prefix.
    // Mutation: in show(), move the `if let held = noticeGate.release(...) {...}`
    // block below the `if let reason = endedReason {...}` block -> RED.
    func testTheHeldNoticeIsReleasedBeforeTheEndedReasonFlush() {
        let show = requireBody("private func show(", in: "AppDelegate.swift")
        guard let release = show.range(of: "noticeGate.release(state: controller.state)"),
              let flush = show.range(of: "if let reason = endedReason") else {
            return XCTFail("show() lost the notice release or the endedReason flush")
        }
        XCTAssertLessThan(release.lowerBound, flush.lowerBound,
                          "the endedReason flush runs before the held notice is released")
    }

    // F2 (call site) — mutation: delete the `AutoUpdateSchedule.noticeShown(admitted` line in
    // notice(_:) -> RED (an update notice would never count as told).
    func testNoticeRecordsAnAnnouncedReleaseOnlyAfterTheGateShowedIt() {
        let notice = requireBody("private func notice(_ raised: NoticeGate.Notice) {", in: "AppDelegate.swift")
        guard let admit = notice.range(of: "guard let admitted = noticeGate.admit("),
              let told = notice.range(of: "AutoUpdateSchedule.noticeShown(admitted,") else {
            return XCTFail("notice() does not record the shown notice")
        }
        XCTAssertLessThan(admit.lowerBound, told.lowerBound, "the release is recorded before the gate let the notice through")
        XCTAssertTrue(notice.contains("told.save(to: autoUpdateDefaults)"), "the told version is not persisted")
        let check = requireBody("private func backgroundUpdateCheck(", in: "AppDelegate.swift")
        XCTAssertFalse(check.contains("lastNotifiedVersion"), "the background check records the release as told at raise time")
    }

    // #198.4 — mutation: put `NSSound.beep()` back in place of the notice -> RED.
    func testARefusedUpdateRowClickSaysWhy() {
        let row = requireBody("@objc private func installOfferedUpdate() {", in: "AppDelegate.swift")
        guard let busy = row.range(of: "guard UpdateGate.decide(installing: updateInstalling) == .proceed else {"),
              let idle = row.range(of: "guard controller.state == .idle else {"),
              let say = row.range(of: "notice(.updateRefused(L10nKey.noticeUpdateBusy.text))"),
              let install = row.range(of: "installUpdate(tag: tag, kind: .update)") else {
            return XCTFail("installOfferedUpdate lost its install gate, its idle gate, the notice or the install")
        }
        XCTAssertTrue(idle.lowerBound < say.lowerBound && say.lowerBound < install.lowerBound)
        // A click during the install's relaunch wait must not say the update did not start.
        XCTAssertLessThan(busy.lowerBound, idle.lowerBound, "the install gate must come before the idle gate")
        XCTAssertFalse(row[idle.lowerBound..<install.lowerBound].contains("NSSound.beep()"), "the refusal only beeps")
    }

    // MAJOR call site — mutation: pass `releasedNotice: false`, or call `notice(reason)`
    // unconditionally, in show(.idle) -> RED.
    func testShowDoesNotFlushTheEndedReasonOverAReleasedNotice() {
        let show = requireBody("private func show(", in: "AppDelegate.swift")
        guard let release = show.range(of: "if let held = noticeGate.release(state: controller.state) {"),
              let flagged = show.range(of: "releasedNotice = true"),
              let flush = show.range(of: "DictationNotice.reasonToFlush(reason, releasedNotice: releasedNotice)") else {
            return XCTFail("show() lost the released-notice flag or the reason rule")
        }
        XCTAssertTrue(release.lowerBound < flagged.lowerBound && flagged.lowerBound < flush.lowerBound)
        XCTAssertFalse(show.contains("notice(reason)"), "the reason is flushed without the rule")
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
