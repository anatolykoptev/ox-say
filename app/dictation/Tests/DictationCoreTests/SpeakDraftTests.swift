import XCTest
@testable import DictationCore

final class SpeakDraftTests: XCTestCase {
    private let key: (L10nKey) -> String = { $0.rawValue }

    func testFirstRunGetsTheSampleAndLaterRunsKeepTheirText() {
        XCTAssertFalse(SpeakDraft.initial(stored: nil, firstRun: true, language: "ru", text: key).isEmpty)
        XCTAssertEqual(SpeakDraft.initial(stored: "мой текст", firstRun: true, language: "ru", text: key), "мой текст")
        XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: false, language: "ru", text: key), "")
        XCTAssertEqual(SpeakDraft.initial(stored: "мой текст", firstRun: false, language: "ru", text: key), "мой текст")
    }

    /// A text the person emptied on purpose stays empty after the first run.
    func testAnEmptiedDraftStaysEmpty() {
        XCTAssertEqual(SpeakDraft.initial(stored: "", firstRun: false, language: "en", text: key), "")
    }

    /// Mutation: SpeakDraft.initial, ignore the language (always the .en key) -> RED.
    func testTheSampleFollowsTheLanguage() {
        XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "ru", text: key), L10nKey.speakSampleRu.rawValue)
        XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "ru-RU", text: key), L10nKey.speakSampleRu.rawValue)
        XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "en", text: key), L10nKey.speakSampleEn.rawValue)
        XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "de", text: key), L10nKey.speakSampleEn.rawValue)
    }

    func testTheShippedSamplesAreTheApprovedSentences() {
        let en = ShippedStrings.localizer("en"), ru = ShippedStrings.localizer("ru")
        let sampleRu = "Привет! Это мой первый голос. Сегодня расскажу, почему короткие ролики работают лучше длинных."
        let sampleEn = "Hi! This is my first voice. Today I will explain why short videos work better than long ones."
        for t in [en, ru] {
            XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "ru", text: t), sampleRu)
            XCTAssertEqual(SpeakDraft.initial(stored: nil, firstRun: true, language: "en", text: t), sampleEn)
        }
    }

    func testTheSampleFitsTheFastVoice() {
        XCTAssertLessThan(ShippedStrings.table("ru")["speak.sample.ru"]?.unicodeScalars.count ?? Int.max, SpeechClient.maxInputChars)
    }
}
