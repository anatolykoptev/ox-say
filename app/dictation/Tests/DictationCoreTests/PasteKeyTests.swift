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
}
