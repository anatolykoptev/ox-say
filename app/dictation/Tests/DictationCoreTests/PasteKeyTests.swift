import XCTest
@testable import DictationCore

/// The ⌘V keystroke must land on the key that types "v" in the layout the user
/// is typing in — not on the QWERTY position, which on Dvorak is "k" and would
/// send ⌘K instead of pasting.
final class PasteKeyTests: XCTestCase {
    func testQWERTYMapsVToTheANSIKey() {
        XCTAssertEqual(PasteKey.commandV(lookup: { $0 == 9 ? "v" : nil }), 9)
    }

    // Mutation: `PasteKey.commandV` returning PasteKey.ansiV unconditionally ->
    // RED here (a Dvorak "v" is not on the ANSI V key).
    func testDvorakMapsVToThePeriodKey() {
        // In Dvorak the letter v sits on the QWERTY "." position, key code 47.
        XCTAssertEqual(PasteKey.commandV(lookup: { $0 == 47 ? "v" : nil }), 47)
    }

    func testALayoutWithoutVFallsBackToTheANSIKey() {
        // e.g. Turkmen: no key types "v", even under ⌘.
        XCTAssertEqual(PasteKey.commandV(lookup: { _ in nil }), PasteKey.ansiV)
    }

    /// The Unicode string the synthetic ⌘V / ⌘C events carry: the letter the key is chosen to type under ⌘.
    func testTheEventsCarryTheLetterTheirKeyTypesUnderCommand() {
        XCTAssertEqual(PasteKey.commandVUnits, [0x76])
        XCTAssertEqual(PasteKey.commandCUnits, [0x63])
    }

    private func appBody(_ file: String, after signature: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/\(file)")
        let source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("\(signature) not found in \(file)"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// #58: under "Dvorak - QWERTY Command" the event built for the chosen key code carries the plain table's letter
    /// ("k" for the QWERTY V position), and an app matching key equivalents on the event's string would miss the paste.
    /// Both the key-down and the key-up carry the letter explicitly. The same holds for the speak-selection copy.
    /// Mutations (call site): PasteOutput.postCommandV, delete the `down?.keyboardSetUnicodeString(` line -> RED; delete
    /// the `up?.keyboardSetUnicodeString(` line -> RED; SelectionCapture.postCommandC, delete either -> RED.
    func testTheSyntheticCommandKeysCarryTheirLetter() {
        let paste = appBody("PasteOutput.swift", after: "private func postCommandV() {")
        XCTAssertTrue(paste.contains("down?.keyboardSetUnicodeString(stringLength: PasteKey.commandVUnits.count, unicodeString: PasteKey.commandVUnits)"),
                      "the key-down of the synthetic paste has no explicit letter")
        XCTAssertTrue(paste.contains("up?.keyboardSetUnicodeString(stringLength: PasteKey.commandVUnits.count, unicodeString: PasteKey.commandVUnits)"),
                      "the key-up of the synthetic paste has no explicit letter")
        let copy = appBody("SelectionCapture.swift", after: "private func postCommandC() {")
        XCTAssertTrue(copy.contains("down?.keyboardSetUnicodeString(stringLength: PasteKey.commandCUnits.count, unicodeString: PasteKey.commandCUnits)"),
                      "the key-down of the synthetic copy has no explicit letter")
        XCTAssertTrue(copy.contains("up?.keyboardSetUnicodeString(stringLength: PasteKey.commandCUnits.count, unicodeString: PasteKey.commandCUnits)"),
                      "the key-up of the synthetic copy has no explicit letter")
    }
}
