import XCTest
@testable import DictationCore

final class SpeakClipsTests: XCTestCase {
    private func clip(_ i: Int, bytes: Int, text: String = "text") -> SpeakClip {
        SpeakClip(id: "\(i)", title: "t\(i)", text: text, voice: nil, seconds: 1,
                  wav: Data(count: bytes), created: Date(timeIntervalSince1970: Double(i)))
    }

    func testClipsKeepTheNewestTwentyAndTheByteBudget() {
        var list: [SpeakClip] = []
        for i in 0..<25 { list = SpeakClips.append(clip(i, bytes: 1_000), to: list) }
        XCTAssertEqual(list.count, 20)
        XCTAssertEqual(list.first?.id, "24")
        XCTAssertEqual(list.last?.id, "5")
        let big = SpeakClips.append(clip(99, bytes: 150_000_000), to: SpeakClips.append(clip(98, bytes: 100_000_000), to: []))
        XCTAssertEqual(big.map(\.id), ["99"], "the byte budget drops the older clip")
    }

    func testAClipOverTheBudgetOnItsOwnIsStillKept() {
        XCTAssertEqual(SpeakClips.append(clip(1, bytes: 250_000_000), to: []).map(\.id), ["1"])
    }

    func testTheTitleIsTheFirstWordsOfTheText() {
        XCTAssertEqual(SpeakClips.title(of: "  Привет, это мой первый голос. Сегодня расскажу дальше  "), "Привет, это мой первый голос. Сегодня…")
        XCTAssertEqual(SpeakClips.title(of: "Short one"), "Short one")
        XCTAssertEqual(SpeakClips.title(of: "Hi! This is my first voice. Today I will explain"), "Hi! This is my first voice…")
        XCTAssertEqual(SpeakClips.title(of: "One two three four five six."), "One two three four five six.", "nothing is cut, so nothing is trimmed")
        XCTAssertEqual(SpeakClips.title(of: "   \n "), "")
    }

    func testTheSaveNameIsASafeFileName() {
        XCTAssertEqual(SpeakClips.fileName(forTitle: "a/b: c"), "a-b- c.wav")
        XCTAssertEqual(SpeakClips.fileName(forTitle: "   "), "voiceover.wav")
        XCTAssertEqual(SpeakClips.fileName(forTitle: ".hidden"), "hidden.wav")
    }

    func testSecondsRenderAsMinutesAndSeconds() {
        XCTAssertEqual(SpeakClips.clock(0), "0:00")
        XCTAssertEqual(SpeakClips.clock(65.4), "1:05")
        XCTAssertEqual(SpeakClips.clock(-3), "0:00")
    }

    /// Equality ignores the audio bytes: the window values are compared on every redraw and hold up to 200 MB.
    func testTwoClipsWithTheSameIdentityAreEqualWithoutComparingTheAudio() {
        XCTAssertEqual(clip(1, bytes: 10), clip(1, bytes: 10))
        XCTAssertNotEqual(clip(1, bytes: 10), clip(2, bytes: 10))
    }
}

final class SpeakVoiceAndSelectionTests: XCTestCase {
    /// A voice that was deleted since the clip was made is not asked for again.
    /// Mutation: SpeakVoice.existing, return `voice` unchecked -> RED.
    func testAVoiceThatIsGoneFallsBackToTheStandardOne() {
        XCTAssertEqual(SpeakVoice.existing("mara", in: ["mara", "ruslan"]), "mara")
        XCTAssertNil(SpeakVoice.existing("mara", in: ["ruslan"]))
        XCTAssertNil(SpeakVoice.existing(nil, in: ["mara"]))
    }

    /// Choosing another clip would drop the take that is being made; the list waits for it.
    /// Mutation: SpeakPhase.allowsSelection, return true -> RED.
    func testNoClipCanBeChosenWhileATakeIsBeingMade() {
        XCTAssertFalse(SpeakPhase.generating.allowsSelection)
        for phase in [SpeakPhase.idle, .ready, .failed("x")] { XCTAssertTrue(phase.allowsSelection, "\(phase)") }
    }

    /// One missed poll after an answer keeps the studio note and its install link; nothing known yet shows nothing.
    /// Mutation: StudioAvailability.held, ignore `waiting` -> RED.
    func testOneMissedPollKeepsTheStudioNote() {
        XCTAssertEqual(StudioAvailability.held(previous: .notInstalled, status: nil, waiting: true), .notInstalled)
        XCTAssertEqual(StudioAvailability.held(previous: .notInstalled, status: nil, waiting: false), .unknown)
        let answered = DaemonStatus(version: "1", studioAvailable: true, studioReason: nil)
        XCTAssertEqual(StudioAvailability.held(previous: .notInstalled, status: answered, waiting: true), .available)
    }
}
