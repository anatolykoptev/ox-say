import Foundation
import XCTest
@testable import DictationCore

/// The Voices page's behaviour, run against a fake daemon: the glue (VoiceSource) only carries these results to the window.
@MainActor
final class VoiceLibrarySessionTests: XCTestCase {
    private func entry(_ id: String, _ label: String? = nil) -> VoiceEntry {
        VoiceEntry(id: id, label: label ?? id, kind: .recorded)
    }

    /// A daemon with a voice list, and a UserDefaults-like pair of picks. On the main actor like the session, so the
    /// ops closures it hands out run where the test reads the same state.
    @MainActor private final class Fake {
        var voices: [VoiceEntry]
        var listError: Error?
        var deleteError: Error?
        var labelError: Error?
        var speakError: Error?
        var labelCalls: [(String, String)] = []
        var deleteCalls: [String] = []
        var spoken: [(String, String, String)] = []
        var stored: ReadAloudPicks
        var writes = 0
        init(voices: [VoiceEntry], picks: ReadAloudPicks = ReadAloudPicks(russian: nil, english: nil)) {
            self.voices = voices; stored = picks
        }
        func session() -> VoiceLibrarySession {
            VoiceLibrarySession(
                ops: VoiceLibraryOps(
                    list: { [unowned self] in if let e = listError { throw e }; return voices },
                    setLabel: { [unowned self] id, label in
                        labelCalls.append((id, label))
                        if let e = labelError { throw e }
                        voices = voices.map { $0.id == id ? VoiceEntry(id: id, label: label, kind: $0.kind) : $0 }
                    },
                    delete: { [unowned self] id in
                        deleteCalls.append(id)
                        if let e = deleteError { throw e }
                        voices.removeAll { $0.id == id }
                    },
                    speak: { [unowned self] text, voice, language in
                        spoken.append((text, voice, language))
                        if let e = speakError { throw e }
                        return Data([1, 2, 3])
                    }),
                readPicks: { [unowned self] in stored },
                writePicks: { [unowned self] in stored = $0; writes += 1 },
                text: ShippedStrings.localizer("en"))
        }
    }

    // MARK: pure pieces

    func testADeletedVoiceIsDroppedFromTheReadAloudPicks() {
        let r = VoicePicksCleanup.afterDelete(id: "moy-golos", russian: "moy-golos", english: "daniel")
        XCTAssertNil(r.russian); XCTAssertEqual(r.english, "daniel")
        let both = VoicePicksCleanup.afterDelete(id: "x", russian: "x", english: "x")
        XCTAssertNil(both.russian); XCTAssertNil(both.english)
        XCTAssertEqual(VoicePicksCleanup.afterDelete(id: "x", russian: MenuSections.randomVoice, english: nil).russian,
                       MenuSections.randomVoice, "the random pick names no voice")
    }

    func testThePreviewSentenceFollowsTheLanguageNotTheLabel() {
        let e = VoiceEntry(id: "moy-golos", label: "Мой голос", kind: .recorded)
        XCTAssertTrue(VoicePreview.sentence(for: e, locale: "ru").contains("голос"))
        XCTAssertFalse(VoicePreview.sentence(for: e, locale: "en").contains("голос"))
        XCTAssertEqual(VoicePreview.language(locale: "ru"), "russian")
        XCTAssertEqual(VoicePreview.language(locale: "en"), "english")
    }

    func testALabelIsTrimmedAndRefusedWhenEmptyLongOrWithControlCharacters() {
        XCTAssertEqual(VoiceLabel.clean("  Спокойный диктор  "), "Спокойный диктор")
        XCTAssertNil(VoiceLabel.clean("   "))
        XCTAssertNil(VoiceLabel.clean(""))
        XCTAssertNil(VoiceLabel.clean(String(repeating: "я", count: VoiceLabel.maxChars + 1)))
        XCTAssertNotNil(VoiceLabel.clean(String(repeating: "я", count: VoiceLabel.maxChars)))
        XCTAssertNil(VoiceLabel.clean("a\nb"))
        XCTAssertNil(VoiceLabel.clean("a\u{07}b"))
    }

    /// The daemon's `normalizeLabel` also refuses line/paragraph separators and bidi controls, and counts runes
    /// (Unicode scalars), not graphemes.
    func testALabelWithSeparatorsBidiControlsOrTooManyScalarsIsRefused() {
        XCTAssertNil(VoiceLabel.clean("a\u{2028}b"), "a line separator inside")
        XCTAssertNil(VoiceLabel.clean("a\u{2029}b"), "a paragraph separator inside")
        XCTAssertNil(VoiceLabel.clean("a\u{202E}b"), "a bidi override")
        XCTAssertNil(VoiceLabel.clean("a\u{2067}b"), "a bidi isolate")
        // One grapheme of seven scalars each: 60 graphemes pass a grapheme count but not the daemon's rune count.
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        XCTAssertEqual(family.count, VoiceLabel.maxChars)
        XCTAssertNil(VoiceLabel.clean(family), "the daemon counts runes, so the app counts scalars")
        XCTAssertNotNil(VoiceLabel.clean("семья 👨‍👩‍👧‍👦"), "a ZWJ under the cap is a label the daemon takes")
        XCTAssertNotNil(VoiceLabel.clean("голос 👍"), "a real emoji is still a fine label")
    }

    // MARK: delete and the read-aloud picks

    /// The journey: two voices, the one picked for Russian read-aloud is deleted, then a Russian text is read aloud.
    func testDeletingThePickedVoiceLeavesReadAloudOnTheDefaultVoice() async {
        let fake = Fake(voices: [entry("a"), entry("b")], picks: ReadAloudPicks(russian: "a", english: "b"))
        let s = fake.session()
        await s.reload()
        let notice = await s.delete(id: "a")
        XCTAssertNil(notice)
        XCTAssertEqual(s.entries.map(\.id), ["b"])
        XCTAssertNil(fake.stored.russian, "the stored Russian pick no longer names the deleted voice")
        XCTAssertEqual(fake.stored.english, "b")
        XCTAssertEqual(s.picks, fake.stored)
        XCTAssertNil(VoicePick.voice(for: "Привет, мир", russian: fake.stored.russian, english: fake.stored.english),
                     "read-aloud sends no voice, so the engine default speaks")
    }

    /// Mutation: VoiceLibrarySession.delete, writePicks called also when the daemon refused -> RED.
    func testAFailedDeleteLeavesThePicksAndTheListAlone() async {
        let fake = Fake(voices: [entry("a"), entry("b")], picks: ReadAloudPicks(russian: "a", english: nil))
        fake.deleteError = StudioError.daemonUnreachable
        let s = fake.session()
        await s.reload()
        let notice = await s.delete(id: "a")
        XCTAssertEqual(notice, StudioError.daemonUnreachable.message(text: ShippedStrings.localizer("en")))
        XCTAssertEqual(fake.stored.russian, "a")
        XCTAssertEqual(fake.writes, 0, "a failed delete writes no pick at all")
        XCTAssertEqual(s.entries.map(\.id), ["a", "b"])
    }

    func testAVoiceThatIsAlreadyGoneStillCleansThePicks() async {
        let fake = Fake(voices: [entry("b")], picks: ReadAloudPicks(russian: "a", english: nil))
        fake.deleteError = StudioError.refused(status: 404, message: "")
        let s = fake.session()
        await s.reload()
        let notice = await s.delete(id: "a")
        XCTAssertNil(notice)
        XCTAssertNil(fake.stored.russian)
    }

    func testDeletingAnotherVoiceTouchesNoPick() async {
        let fake = Fake(voices: [entry("a"), entry("b")], picks: ReadAloudPicks(russian: "a", english: nil))
        let s = fake.session()
        await s.reload()
        _ = await s.delete(id: "b")
        XCTAssertEqual(fake.writes, 0)
        XCTAssertEqual(fake.stored.russian, "a")
    }

    // MARK: reads

    /// A failed read is never an empty library; a refresh that fails keeps the list that was on screen.
    func testAFailedReadIsNotAnEmptyLibrary() async {
        let fake = Fake(voices: [entry("a")])
        fake.listError = StudioError.daemonUnreachable
        let s = fake.session()
        await s.reload()
        guard case .unreachable = s.pageState else { return XCTFail("\(s.pageState)") }
        fake.listError = nil
        await s.reload()
        XCTAssertEqual(s.pageState, .list(stale: nil))
        fake.listError = StudioError.timedOut
        await s.reload()
        XCTAssertEqual(s.entries.map(\.id), ["a"], "the last good list stays")
        guard case .list(let stale) = s.pageState, stale != nil else { return XCTFail("\(s.pageState)") }
    }

    func testNoVoicesIsEmptyOnlyAfterASuccessfulRead() async {
        let fake = Fake(voices: [])
        let s = fake.session()
        XCTAssertEqual(s.pageState, .loading)
        await s.reload()
        XCTAssertEqual(s.pageState, .empty)
    }

    /// A list read that started before a delete and answers after it must not bring the voice back.
    func testALateListAnswerDoesNotResurrectADeletedVoice() async {
        let fake = Fake(voices: [entry("a"), entry("b")])
        let gate = AsyncGate<[VoiceEntry]>()
        var first = true
        let base = fake.session()
        _ = base
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { [unowned fake] in
                    if first { first = false; return await gate.wait() }
                    return fake.voices
                },
                setLabel: { _, _ in },
                delete: { [unowned fake] id in fake.voices.removeAll { $0.id == id } },
                speak: { _, _, _ in Data() }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in },
            text: ShippedStrings.localizer("en"))
        let slow = Task { await s.reload() }
        await gate.waiting()
        _ = await s.delete(id: "a")
        XCTAssertEqual(s.entries.map(\.id), ["b"])
        gate.open([entry("a"), entry("b")])
        await slow.value
        XCTAssertEqual(s.entries.map(\.id), ["b"])
    }

    /// A delete followed by a failed re-read: the stale read that began earlier answers while the delete is
    /// still on the wire, and must not resurrect the voice. Mutation: `epoch += 1` in `delete` gone -> RED.
    func testADeletedVoiceStaysGoneWhenTheNextReadFailsAndAnEarlyOneAnswersLate() async {
        let fake = Fake(voices: [entry("a"), entry("b")])
        let slowList = AsyncGate<[VoiceEntry]>()
        let deleteCall = AsyncGate<Void>()
        var calls = 0
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { [unowned fake] in
                    calls += 1
                    switch calls {
                    case 1: return fake.voices
                    case 2: return await slowList.wait()
                    default: throw StudioError.daemonUnreachable
                    }
                },
                setLabel: { _, _ in },
                delete: { [unowned fake] id in
                    await deleteCall.wait()
                    fake.voices.removeAll { $0.id == id }
                },
                speak: { _, _, _ in Data() }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in },
            text: ShippedStrings.localizer("en"))
        await s.reload()
        let slow = Task { await s.reload() }
        await slowList.waiting()
        let deleting = Task { await s.delete(id: "a") }
        await deleteCall.waiting()
        XCTAssertEqual(s.entries.map(\.id), ["b"], "the delete takes it off before the daemon answers")
        slowList.open([entry("a"), entry("b")])
        await slow.value
        deleteCall.open(())
        let notice = await deleting.value
        XCTAssertNil(notice)
        XCTAssertEqual(s.entries.map(\.id), ["b"], "the stale answer must not bring it back")
    }

    // MARK: the offered ids

    /// What the pickers and the menu may offer: nothing before the first good read, the entries' ids after —
    /// a failed refresh keeps offering what is still held, a deleted voice included no more.
    /// Mutation: `offeredIDs` gated on `load == .loaded` -> RED.
    func testAFailedRefreshAfterADeleteStillOffersTheRemainingVoices() async {
        let fake = Fake(voices: [entry("a"), entry("b")])
        let s = fake.session()
        XCTAssertNil(s.offeredIDs, "before any good read there is nothing to offer")
        await s.reload()
        XCTAssertEqual(s.offeredIDs, ["a", "b"])
        fake.listError = StudioError.daemonUnreachable
        _ = await s.delete(id: "a")
        XCTAssertEqual(s.entries.map(\.id), ["b"])
        XCTAssertEqual(s.offeredIDs, ["b"], "the failed refresh must not offer the deleted voice")
    }

    /// A daemon never reached offers nothing; an empty library read offers an empty list, which is a real answer.
    func testTheOfferedIDsAreNilOnlyUntilTheFirstGoodRead() async {
        let fake = Fake(voices: [entry("a")])
        fake.listError = StudioError.daemonUnreachable
        let s = fake.session()
        await s.reload()
        XCTAssertNil(s.offeredIDs, "unreachable with nothing read offers nothing")
        fake.voices = []
        fake.listError = nil
        await s.reload()
        XCTAssertEqual(s.offeredIDs, [], "a good read of no voices offers an empty list")
    }

    // MARK: rename

    /// Mutation: VoiceLibrarySession.rename, drop the `VoiceLabel.clean` guard -> RED (an empty label reaches the daemon).
    func testARenameWithAnInvalidLabelNeverReachesTheDaemon() async {
        let fake = Fake(voices: [entry("a")])
        let s = fake.session()
        await s.reload()
        for bad in ["", "   ", "x\ny", String(repeating: "я", count: 61)] {
            let notice = await s.rename(id: "a", label: bad)
            XCTAssertEqual(notice, ShippedStrings.localizer("en")(.voicesRenameInvalid), bad)
        }
        XCTAssertTrue(fake.labelCalls.isEmpty)
    }

    func testARenameSendsTheTrimmedLabelAndShowsIt() async {
        let fake = Fake(voices: [entry("a", "Old")])
        let s = fake.session()
        await s.reload()
        let notice = await s.rename(id: "a", label: "  Новый голос ")
        XCTAssertNil(notice)
        XCTAssertEqual(fake.labelCalls.map(\.1), ["Новый голос"])
        XCTAssertEqual(s.entries.first?.label, "Новый голос")
        XCTAssertEqual(s.entries.first?.id, "a", "the id on disk never changes")
    }

    func testRenamingToTheShownLabelSendsNothing() async {
        let fake = Fake(voices: [entry("a", "Same")])
        let s = fake.session()
        await s.reload()
        _ = await s.rename(id: "a", label: " Same ")
        XCTAssertTrue(fake.labelCalls.isEmpty)
    }

    func testAFailedRenameSaysWhyAndKeepsTheOldLabel() async {
        let fake = Fake(voices: [entry("a", "Old")])
        fake.labelError = StudioError.timedOut
        let s = fake.session()
        await s.reload()
        let notice = await s.rename(id: "a", label: "New")
        XCTAssertEqual(notice, StudioError.timedOut.message(text: ShippedStrings.localizer("en")))
        XCTAssertEqual(s.entries.first?.label, "Old")
    }

    /// A timed-out PATCH may have landed anyway: the rename says it failed, but a re-read still shows the new
    /// label. Mutation: `await reload()` on the rename error path gone -> RED.
    func testARenameThatTimedOutStillShowsTheLabelTheDaemonTook() async {
        let fake = Fake(voices: [entry("a", "Old")])
        let s = fake.session()
        await s.reload()
        fake.labelError = StudioError.timedOut
        fake.voices = [entry("a", "New")]   // the PATCH landed on the daemon; only its answer was lost
        let notice = await s.rename(id: "a", label: "New")
        XCTAssertEqual(notice, StudioError.timedOut.message(text: ShippedStrings.localizer("en")))
        XCTAssertEqual(s.entries.first?.label, "New", "the re-read shows what the daemon stored")
    }

    /// The other side of a timeout: the PATCH did not land, and the same re-read takes the optimistic label back.
    /// Mutation: `await reload()` on the rename error path gone -> RED.
    func testARenameThatTimedOutButDidNotLandShowsTheOldLabel() async {
        let fake = Fake(voices: [entry("a", "Old")])
        let s = fake.session()
        await s.reload()
        fake.labelError = StudioError.timedOut   // the PATCH never reached the daemon
        let notice = await s.rename(id: "a", label: "New")
        XCTAssertEqual(notice, StudioError.timedOut.message(text: ShippedStrings.localizer("en")))
        XCTAssertEqual(s.entries.first?.label, "Old", "the re-read takes back the label the daemon never took")
    }

    /// The rename analogue of the delete case: the stale read answers while the PATCH is still on the wire, and
    /// must not undo the new label. Mutation: `epoch += 1` in `rename` gone -> RED.
    func testARenamedVoiceKeepsItsLabelWhenTheNextReadFailsAndAnEarlyOneAnswersLate() async {
        let fake = Fake(voices: [entry("a", "Old"), entry("b")])
        let slowList = AsyncGate<[VoiceEntry]>()
        let labelCall = AsyncGate<Void>()
        var calls = 0
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { [unowned fake] in
                    calls += 1
                    switch calls {
                    case 1: return fake.voices
                    case 2: return await slowList.wait()
                    default: throw StudioError.daemonUnreachable
                    }
                },
                setLabel: { [unowned fake] id, label in
                    await labelCall.wait()
                    fake.voices = fake.voices.map { $0.id == id ? VoiceEntry(id: id, label: label, kind: $0.kind) : $0 }
                },
                delete: { _ in },
                speak: { _, _, _ in Data() }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in },
            text: ShippedStrings.localizer("en"))
        await s.reload()
        let slow = Task { await s.reload() }
        await slowList.waiting()
        let renaming = Task { await s.rename(id: "a", label: "New") }
        await labelCall.waiting()
        XCTAssertEqual(s.entries.map(\.label), ["New", "b"], "the new label shows before the daemon answers")
        slowList.open([entry("a", "Old"), entry("b")])
        await slow.value
        labelCall.open(())
        let notice = await renaming.value
        XCTAssertNil(notice)
        XCTAssertEqual(s.entries.map(\.label), ["New", "b"], "the stale answer must not bring the old label back")
    }

    // MARK: preview

    func testAPreviewSpeaksTheSentenceWithThatVoiceInTheLanguage() async {
        let fake = Fake(voices: [entry("a")])
        let s = fake.session()
        await s.reload()
        let outcome = await s.preview(id: "a", locale: "ru")
        XCTAssertEqual(outcome, .play(Data([1, 2, 3])))
        XCTAssertEqual(s.playingID, "a")
        XCTAssertEqual(fake.spoken.count, 1)
        XCTAssertEqual(fake.spoken[0].1, "a")
        XCTAssertEqual(fake.spoken[0].2, "russian")
        s.previewEnded()
        XCTAssertNil(s.playingID)
    }

    func testAFailedPreviewSaysWhyAndPlaysNothing() async {
        let fake = Fake(voices: [entry("a")])
        fake.speakError = SpeechError.engineUnavailable
        let s = fake.session()
        await s.reload()
        let outcome = await s.preview(id: "a", locale: "en")
        XCTAssertEqual(outcome, .failed(SpeechError.engineUnavailable.message(text: ShippedStrings.localizer("en"))))
        XCTAssertNil(s.playingID)
    }

    /// A stop (or a second preview) while the daemon is still synthesising drops the first answer.
    func testAPreviewAnsweredAfterAStopIsDropped() async {
        let gate = AsyncGate<Data>()
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(list: { [] }, setLabel: { _, _ in }, delete: { _ in }, speak: { _, _, _ in await gate.wait() }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in }, text: ShippedStrings.localizer("en"))
        let slow = Task { await s.preview(id: "a", locale: "en") }
        await gate.waiting()
        XCTAssertEqual(s.playingID, "a", "the stop button shows while the sample is made")
        s.stopPreview()
        XCTAssertNil(s.playingID)
        gate.open(Data([9]))
        let outcome = await slow.value
        XCTAssertEqual(outcome, .dropped)
        XCTAssertNil(s.playingID)
    }

    func testDeletingThePlayingVoiceStopsItsPreview() async {
        let fake = Fake(voices: [entry("a"), entry("b")])
        let s = fake.session()
        await s.reload()
        _ = await s.preview(id: "a", locale: "en")
        XCTAssertEqual(s.playingID, "a")
        _ = await s.delete(id: "a")
        XCTAssertNil(s.playingID)
    }

    /// A delete that lands while the sample is still being made drops its answer: the glue is told `.dropped`,
    /// so nothing starts playing. Mutation: `if playingID == id { stopPreview() }` in `delete` gone -> RED.
    func testADeleteDropsTheAnswerOfAPreviewStillBeingMade() async {
        let fake = Fake(voices: [entry("a"), entry("b")])
        let gate = AsyncGate<Data>()
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { [unowned fake] in fake.voices },
                setLabel: { _, _ in },
                delete: { [unowned fake] id in fake.voices.removeAll { $0.id == id } },
                speak: { _, _, _ in await gate.wait() }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in },
            text: ShippedStrings.localizer("en"))
        await s.reload()
        let slow = Task { await s.preview(id: "a", locale: "en") }
        await gate.waiting()
        _ = await s.delete(id: "a")
        gate.open(Data([9]))
        let outcome = await slow.value
        XCTAssertEqual(outcome, .dropped)
        XCTAssertNil(s.playingID)
    }

    /// A second preview supersedes the first: one's answer after the other began is dropped too.
    /// Mutation: `previewEpoch += 1` in `preview` gone -> RED.
    func testANewerPreviewDropsTheAnswerStillBeingMade() async {
        let gate = AsyncGate<Data>()
        var calls = 0
        let s = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { [] }, setLabel: { _, _ in }, delete: { _ in },
                speak: { _, _, _ in
                    calls += 1
                    if calls == 1 { return await gate.wait() }
                    return Data([9])
                }),
            readPicks: { ReadAloudPicks(russian: nil, english: nil) }, writePicks: { _ in },
            text: ShippedStrings.localizer("en"))
        let slow = Task { await s.preview(id: "a", locale: "en") }
        await gate.waiting()
        let second = await s.preview(id: "b", locale: "en")
        XCTAssertEqual(second, .play(Data([9])))
        gate.open(Data([1]))
        let outcome = await slow.value
        XCTAssertEqual(outcome, .dropped)
        XCTAssertEqual(s.playingID, "b")
    }
}

/// Holds an async call until the test opens it.
final class AsyncGate<T> {
    private var continuation: CheckedContinuation<T, Never>?
    private var value: T?
    func wait() async -> T {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
    /// Returns once `wait` is parked.
    func waiting() async {
        let deadline = Date().addingTimeInterval(5)
        while continuation == nil, Date() < deadline { await Task.yield() }
    }
    func open(_ v: T) {
        value = v
        continuation?.resume(returning: v)
        continuation = nil
    }
}
