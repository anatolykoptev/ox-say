import Foundation
import XCTest
@testable import DictationCore

/// The Voices page's behaviour, run against a fake daemon: the glue (VoiceSource) only carries these results to the window.
final class VoiceLibrarySessionTests: XCTestCase {
    private func entry(_ id: String, _ label: String? = nil) -> VoiceEntry {
        VoiceEntry(id: id, label: label ?? id, kind: .recorded)
    }

    /// A daemon with a voice list, and a UserDefaults-like pair of picks.
    private final class Fake {
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
