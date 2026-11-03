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

    // MARK: scalars, not Characters

    private static let daemonPattern = try! NSRegularExpression(pattern: VoiceName.idPattern)
    private static func matchesDaemon(_ id: String) -> Bool {
        daemonPattern.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)) == 1
    }

    /// A Character that starts with an ASCII letter can carry combining scalars;
    /// the id must be judged per scalar. These three reached the id before
    /// ("golos-1" + keycap, "x" + underline + "y", "i" + dot) and the daemon refused them.
    /// Mutation F2: VoiceName.id, the `for scalar in ...unicodeScalars` loop back to `for c in label.lowercased()` -> RED.
    func testCombiningScalarsNeverReachTheId() {
        XCTAssertEqual(VoiceName.id(from: "Голос 1\u{FE0F}\u{20E3}", taken: []), "golos-1")
        XCTAssertEqual(VoiceName.id(from: "x\u{0332}y", taken: []), "x-y")
        XCTAssertEqual(VoiceName.id(from: "İ", taken: []), "i")
        // A decomposed й (и + breve) is the same letter as the precomposed one.
        XCTAssertEqual(VoiceName.id(from: "Мои\u{0306} голос", taken: []), "moy-golos")
    }

    /// Whatever scripts, combining marks, emoji and joiners a label mixes, the id
    /// matches the daemon's pattern. Generated from a fixed seed so a failure
    /// reproduces; the pools are not a list of known-bad labels.
    func testGeneratedLabelsAlwaysGiveDaemonValidIds() {
        let pools: [[UInt32]] = [
            Array(0x61...0x7A), Array(0x30...0x39), Array(0x41...0x5A), [0x20, 0x2D, 0x5F, 0x2E],
            Array(0x430...0x44F) + [0x451, 0x456, 0x457, 0x454, 0x491, 0x45E], Array(0x410...0x42F),
            Array(0x300...0x36F), [0x20E3, 0xFE0F, 0xFE0E, 0x200D, 0x200B, 0x0307, 0x0332],
            [0x1F3A4, 0x1F468, 0x1F469, 0x1F467, 0x1F1F7, 0x1F1FA, 0x2764], Array(0x4E00...0x4E40),
            Array(0x627...0x64A), Array(0x3040...0x3060), [0x130, 0xDF, 0xFB01, 0x1E9E, 0x2126],
            [0x0A, 0x09, 0x2028, 0x202E, 0x00A0, 0x0085],
        ]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<3000 {
            var label = ""
            for _ in 0..<(1 + next(70)) {
                let pool = pools[next(pools.count)]
                if let scalar = Unicode.Scalar(pool[next(pool.count)]) { label.unicodeScalars.append(scalar) }
            }
            let id = VoiceName.id(from: label, taken: [])
            XCTAssertTrue(Self.matchesDaemon(id), "\(label.unicodeScalars.map { String($0.value, radix: 16) }) -> \(id)")
            let second = VoiceName.id(from: label, taken: [id])
            XCTAssertTrue(Self.matchesDaemon(second) && second != id, "\(id) -> \(second)")
        }
    }

    // MARK: the daemon's label rules, mirrored

    /// normalizeLabel refuses Cc (U+0000-001F, U+007F-009F), U+2028/2029 and the
    /// bidi controls U+202A-202E, U+2066-2069 — and nothing else. A ZWJ emoji
    /// sequence, a keycap and a variation selector are stored, so they are offered.
    /// Mutation F4: VoiceName.validLabel, the Cc ranges -> `CharacterSet.controlCharacters.contains(scalar)` -> RED.
    func testValidLabelMirrorsTheDaemonExactly() {
        XCTAssertEqual(VoiceName.validLabel("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} Семья"), "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} Семья")
        XCTAssertNotNil(VoiceName.validLabel("1\u{FE0F}\u{20E3}"))
        XCTAssertNotNil(VoiceName.validLabel("a\u{200B}b"))
        XCTAssertNotNil(VoiceName.validLabel("a\u{00AD}b"))
        XCTAssertNotNil(VoiceName.validLabel("a\u{2027}b"))
        var banned: [UInt32] = Array(0x00...0x1F) + Array(0x7F...0x9F) + [0x2028, 0x2029]
        banned += Array(0x202A...0x202E) + Array(0x2066...0x2069)
        for value in banned {
            let label = "a" + String(Unicode.Scalar(value)!) + "b"
            XCTAssertNil(VoiceName.validLabel(label), "U+\(String(value, radix: 16)) inside")
        }
        // At the edges only whitespace trims: a control that is not whitespace stays and refuses.
        XCTAssertNil(VoiceName.validLabel("\u{202E}abc"))
        XCTAssertNil(VoiceName.validLabel("abc\u{0000}"))
    }

    // MARK: Cyrillic beyond Russian

    /// Ukrainian, Belarusian, Serbian/Macedonian and Kazakh letters transliterate
    /// instead of being dropped ("Їжак Іван" used to give "zhak-van").
    /// Mutation F5: VoiceName.cyrillic, the "і", "ї", "є", "ґ", "ў" entries removed -> RED.
    func testNonRussianCyrillicLettersAreTransliterated() {
        XCTAssertEqual(VoiceName.id(from: "Їжак Іван", taken: []), "yizhak-ivan")
        XCTAssertEqual(VoiceName.id(from: "Європа", taken: []), "yevropa")
        XCTAssertEqual(VoiceName.id(from: "Ґанок", taken: []), "ganok")
        XCTAssertEqual(VoiceName.id(from: "Ўрэй", taken: []), "urey")
        XCTAssertEqual(VoiceName.id(from: "Қазақ", taken: []), "qazaq")
        // Every Cyrillic letter in the blocks people type keeps at least one ASCII character.
        for value in (0x410...0x44F) + [0x401, 0x451, 0x404, 0x454, 0x406, 0x456, 0x407, 0x457, 0x490, 0x491, 0x40E, 0x45E,
                                       0x408, 0x458, 0x409, 0x459, 0x40A, 0x45A, 0x40B, 0x45B, 0x40F, 0x45F, 0x402, 0x452,
                                       0x403, 0x453, 0x40C, 0x45C, 0x405, 0x455, 0x4D8, 0x4D9, 0x492, 0x493, 0x49A, 0x49B,
                                       0x4A2, 0x4A3, 0x4E8, 0x4E9, 0x4AE, 0x4AF, 0x4B0, 0x4B1, 0x4BA, 0x4BB] {
            let letter = String(Unicode.Scalar(UInt32(value))!)
            if letter == "ъ" || letter == "ь" || letter == "Ъ" || letter == "Ь" { continue }
            XCTAssertNotEqual(VoiceName.id(from: letter + "x", taken: []), "x", "U+\(String(value, radix: 16)) was dropped")
        }
    }
}
