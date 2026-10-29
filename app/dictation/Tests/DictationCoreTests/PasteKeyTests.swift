import CoreGraphics
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

    /// #58: the synthetic ⌘V / ⌘C, built by the factory the app posts from and read back without posting anything.
    /// Under "Dvorak - QWERTY Command" the event built for the chosen key code carries the plain table's letter ("k" for
    /// the QWERTY V position) unless the letter is set outright; an app matching key equivalents on the string would
    /// miss the paste. Key codes: QWERTY, the Dvorak position of the letter, and one that is never that letter.
    /// Mutation (call site): PasteKey.commandEvents, delete the `event.keyboardSetUnicodeString(` line -> RED
    /// (the unicode string of the 47/38 events is the layout's own); `.maskCommand` -> `[]` -> RED (flags).
    func testTheSyntheticCommandKeysCarryTheirLetterAndOnlyCommand() throws {
        let cases: [(PasteKey.CommandLetter, [UInt16], [CGKeyCode])] = [
            (.v, Array("v".utf16), [9, 47, 38]),
            (.c, Array("c".utf16), [8, 34, 38]),
        ]
        for (letter, expected, codes) in cases {
            for code in codes {
                let events = try XCTUnwrap(PasteKey.commandEvents(letter, keyCode: code, source: nil), "no event for \(letter) on \(code)")
                for (name, event, type) in [("down", events.down, CGEventType.keyDown), ("up", events.up, .keyUp)] {
                    let label = "\(letter) key \(code) \(name)"
                    XCTAssertEqual(event.type, type, label)
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(code), label)
                    var length = 0
                    var buffer = [UniChar](repeating: 0, count: 8)
                    event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
                    XCTAssertEqual(Array(buffer.prefix(length)), expected, "\(label): the letter")
                    XCTAssertTrue(event.flags.contains(.maskCommand), "\(label): Command")
                    let others: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
                    XCTAssertTrue(event.flags.intersection(others).isEmpty, "\(label): only Command, got \(event.flags.rawValue)")
                }
            }
        }
    }

    private func appSource(_ file: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/\(file)")
        return MeetingWiringTests.stripComments((try? String(contentsOf: path, encoding: .utf8)) ?? "")
    }

    private func body(_ source: String, after signature: String) -> String {
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("\(signature) not found"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The app posts what the factory built, and builds nothing of its own.
    /// Mutations (call site): PasteOutput.postCommandV, `PasteKey.commandEvents(.v,` -> a hand-built `CGEvent(` -> RED;
    /// `.v` -> `.c` -> RED; SelectionCapture.postCommandC likewise; delete either `.post(` line -> RED.
    func testTheAppPostsTheEventsOfTheFactory() {
        let paste = body(appSource("PasteOutput.swift"), after: "private func postCommandV() {")
        XCTAssertTrue(paste.contains("PasteKey.commandEvents(.v, keyCode: v, source: source)"))
        XCTAssertTrue(paste.contains("events.down.post(tap: .cghidEventTap)") && paste.contains("events.up.post(tap: .cghidEventTap)"))
        XCTAssertFalse(paste.contains("CGEvent(") || paste.contains("keyboardSetUnicodeString"), "an event made outside the factory")
        let copy = body(appSource("SelectionCapture.swift"), after: "private func postCommandC() {")
        XCTAssertTrue(copy.contains("PasteKey.commandEvents(.c, keyCode: c, source: source)"))
        XCTAssertTrue(copy.contains("events.down.post(tap: .cghidEventTap)") && copy.contains("events.up.post(tap: .cghidEventTap)"))
        XCTAssertFalse(copy.contains("CGEvent(") || copy.contains("keyboardSetUnicodeString"), "an event made outside the factory")
    }
}
