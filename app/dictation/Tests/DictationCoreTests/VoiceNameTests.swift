import Foundation
import XCTest
@testable import DictationCore

final class VoiceNameTests: XCTestCase {
    /// Cyrillic labels transliterate to daemon-safe ids; a collision takes a
    /// numeric suffix inside the same 32-character budget.
    /// Mutation F1: VoiceName.id, `while taken.contains` dropped -> RED.
    func testRussianLabelsBecomeValidUniqueIds() {
        XCTAssertEqual(VoiceName.id(from: "Мой голос", taken: []), "moy-golos")
        XCTAssertEqual(VoiceName.id(from: "Мой голос", taken: ["moy-golos"]), "moy-golos-2")
        XCTAssertEqual(VoiceName.id(from: "Спокойный диктор", taken: []), "spokoynyy-diktor")
        XCTAssertEqual(VoiceName.id(from: "!!!", taken: []), "voice")
    }

    /// Whatever the label holds — emoji, padding, controls, scripts the table
    /// does not cover — the id always matches the daemon's own pattern.
    func testEveryIdMatchesTheDaemonPattern() {
        let re = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9_-]{0,31}$")
        for label in ["Мой голос", String(repeating: "я", count: 80), "  -x-  ", "Ёлка Щука", "Voice 2",
                      "---", "🎤🎶🎙", "a\nb", "Tab\there", "Оркестр 🎻", "_lead", "9lives"] {
            let id = VoiceName.id(from: label, taken: [])
            XCTAssertEqual(re.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1, "\(label) -> \(id)")
        }
    }

    /// An emoji or all-symbol label must not collapse to nothing.
    func testASymbolOnlyLabelGetsTheFallbackId() {
        XCTAssertEqual(VoiceName.id(from: "🎤", taken: []), "voice")
        XCTAssertEqual(VoiceName.id(from: "🎤", taken: ["voice"]), "voice-2")
        XCTAssertEqual(VoiceName.id(from: "— — —", taken: []), "voice")
    }

    /// A suffix that itself collides keeps counting up: the loop, not one try.
    /// Mutation F1 variant: `while taken.contains` -> `if` -> RED (returns "v-2", taken).
    func testACollisionChainKeepsNumbering() {
        XCTAssertEqual(VoiceName.id(from: "v", taken: ["v", "v-2"]), "v-3")
        XCTAssertEqual(VoiceName.id(from: "Voice 2", taken: ["voice-2", "voice-2-2"]), "voice-2-3")
    }

    /// The app never offers a name the daemon refuses (voicemeta.go
    /// normalizeLabel): the trimmed label is what counts — up to 60 runes —
    /// and no control, line-break or bidi character may sit inside it.
    func testALabelTheDaemonWouldRefuseIsNotOffered() {
        XCTAssertEqual(VoiceName.validLabel("  Голос  "), "Голос")
        XCTAssertEqual(VoiceName.validLabel(String(repeating: "я", count: 60))?.count, 60)
        XCTAssertNil(VoiceName.validLabel(String(repeating: "я", count: 61)))
        // A flag is one Character but two runes; the daemon counts runes.
        XCTAssertNotNil(VoiceName.validLabel(String(repeating: "🇷🇺", count: 30)))
        XCTAssertNil(VoiceName.validLabel(String(repeating: "🇷🇺", count: 31)))
        XCTAssertNil(VoiceName.validLabel("a\nb"))
        XCTAssertNil(VoiceName.validLabel("a\tb"))
        XCTAssertNil(VoiceName.validLabel("a\u{2028}b"))
        XCTAssertNil(VoiceName.validLabel("a\u{202A}b"))
        XCTAssertNil(VoiceName.validLabel("   "))
    }

    /// The uniqueness suffix fits inside 32 characters too: the stem is cut to
    /// leave room for it, never appended past the daemon's limit.
    /// Mutation F1: VoiceName.id, `while taken.contains` dropped -> RED.
    func testALongLabelStillGetsItsSuffixWithinTheLimit() {
        let long = String(repeating: "я", count: 80)
        let first = VoiceName.id(from: long, taken: [])
        let second = VoiceName.id(from: long, taken: [first])
        XCTAssertNotEqual(first, second)
        XCTAssertLessThanOrEqual(second.count, 32)
    }
}
