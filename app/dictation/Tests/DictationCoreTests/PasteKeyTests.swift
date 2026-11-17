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

    /// #637: the synthetic ⌘V / ⌘C, built by the factory the app posts from and read back without posting anything.
    /// The events set no Unicode string of their own — an explicit "v"/"c" made Chromium's web content drop the
    /// keystroke — so each is diffed against a CGEvent built without an override for the same key code; the check
    /// holds on any layout. Under "Dvorak - QWERTY Command" the string the system fills is the plain table's letter
    /// for the chosen key ("k" on the QWERTY V position), not the letter the key types with ⌘; no app or test is
    /// known to match key equivalents on it. Key codes: QWERTY, the Dvorak position of the letter, and one that is
    /// never that letter.
    /// Mutation (call site): PasteKey.commandEvents, put back `event.keyboardSetUnicodeString(` -> RED
    /// (the strings the system fills for 47/38/34 are not "v"/"c"); `.maskCommand` -> `[]` -> RED (flags).
    func testTheSyntheticCommandKeysCarryNoExplicitString() throws {
        let cases: [(PasteKey.CommandLetter, [CGKeyCode])] = [
            (.v, [9, 47, 38]),
            (.c, [8, 34, 38]),
        ]
        for (letter, codes) in cases {
            for code in codes {
                let events = try XCTUnwrap(PasteKey.commandEvents(letter, keyCode: code, source: nil), "no event for \(letter) on \(code)")
                for (name, event, type) in [("down", events.down, CGEventType.keyDown), ("up", events.up, .keyUp)] {
                    let label = "\(letter) key \(code) \(name)"
                    XCTAssertEqual(event.type, type, label)
                    XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(code), label)
                    let reference = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code,
                                                        keyDown: type == .keyDown), label)
                    reference.flags = .maskCommand
                    XCTAssertEqual(unicodeString(event), unicodeString(reference),
                                   "\(label): the string the system fills in")
                    XCTAssertEqual(event.flags, .maskCommand, label)
                }
            }
        }
    }

    /// The Unicode string an event carries, as the system filled it or an explicit call set it.
    private func unicodeString(_ event: CGEvent) -> [UniChar] {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        return Array(buffer.prefix(length))
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
