import XCTest
@testable import DictationCore

final class VoicePickTests: XCTestCase {
    func testCyrillicTextPicksTheRussianVoice() {
        XCTAssertEqual(VoicePick.voice(for: "привет, мир", russian: "ru-ruslan", english: "en-snakes"), "ru-ruslan")
    }

    func testLatinTextPicksTheEnglishVoice() {
        XCTAssertEqual(VoicePick.voice(for: "hello world", russian: "ru-ruslan", english: "en-snakes"), "en-snakes")
    }

    /// The daemon's langHint short-circuits on the first Cyrillic rune, so a
    /// Latin lead-in still lands on the Russian pick.
    func testAnyCyrillicWinsOverLatin() {
        XCTAssertEqual(VoicePick.voice(for: "hello привет", russian: "ru-ruslan", english: "en-snakes"), "ru-ruslan")
        XCTAssertEqual(VoicePick.languageHint(of: "café"), "en")
    }

    func testAccentedLatinIsEnglish() {
        XCTAssertEqual(VoicePick.languageHint(of: "naïve Übermensch"), "en")
    }

    /// Go's Latin table reaches into Phonetic Extensions (ᴀ U+1D00) and
    /// Roman numerals; the daemon's langHint sees the same.
    func testExtendedLatinBlocksAreEnglish() {
        XCTAssertEqual(VoicePick.languageHint(of: "\u{1D00}\u{207F}"), "en")
        XCTAssertEqual(VoicePick.languageHint(of: "\u{2160}"), "en")
    }

    /// Greek letters inside the Phonetic Extensions block are not Latin —
    /// the daemon would not classify them either.
    func testGreekInsidePhoneticBlockIsNotEnglish() {
        XCTAssertNil(VoicePick.languageHint(of: "\u{1D66}"))
        XCTAssertEqual(VoicePick.languageHint(of: "\u{1D2B}"), "ru")
    }

    /// Digits, punctuation and the symbols sandwiched between Latin letters
    /// carry no language — the pick falls through to nil so the daemon's
    /// configured default applies.
    func testNoLettersLeavesTheDaemonDefault() {
        XCTAssertNil(VoicePick.voice(for: "123…", russian: "ru-ruslan", english: "en-snakes"))
        XCTAssertNil(VoicePick.languageHint(of: "5×5"))
        XCTAssertNil(VoicePick.languageHint(of: "[```]"))
    }

    /// The engine's random voice stays reachable per language.
    func testRandomPickPassesThrough() {
        XCTAssertEqual(VoicePick.voice(for: "hello", russian: nil, english: "default"), "default")
    }

    func testUnsetPickStaysNil() {
        XCTAssertNil(VoicePick.voice(for: "привет", russian: nil, english: "en-snakes"))
    }
}
