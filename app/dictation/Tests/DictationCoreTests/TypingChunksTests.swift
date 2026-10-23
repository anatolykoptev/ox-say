import XCTest
@testable import DictationCore

/// TypingChunks splits dictated text for CGEventKeyboardSetUnicodeString,
/// which takes at most 20 UTF-16 units per event. A chunk must never end
/// inside a surrogate pair or a grapheme cluster — Russian text and emoji
/// arrive whole.
final class TypingChunksTests: XCTestCase {
    // Mutation: split Array(text.utf16) into plain 20-unit slices -> RED (the
    // pair at the boundary is cut in half and decodes as U+FFFD).
    func testASurrogatePairAtTheChunkBoundaryStaysWhole() {
        let text = String(repeating: "a", count: 19) + "😀" + "bcd"
        let chunks = TypingChunks.split(text)
        XCTAssertEqual(chunks, [String(repeating: "a", count: 19), "😀bcd"])
        XCTAssertEqual(chunks.joined(), text)
    }

    // Mutation: same plain 20-unit slicing -> RED (the base letter goes out in
    // chunk 1 and its combining mark opens chunk 2, split apart).
    func testACombiningMarkAtTheChunkBoundaryStaysWithItsBase() {
        let text = String(repeating: "a", count: 19) + "e\u{301}" + "zz"
        let chunks = TypingChunks.split(text)
        XCTAssertEqual(chunks, [String(repeating: "a", count: 19), "e\u{301}zz"])
        XCTAssertEqual(chunks.joined(), text)
    }

    // A cluster over the cap cannot be sent whole: it is split at scalar
    // boundaries (never inside a surrogate pair), so nothing is lost.
    func testAClusterOverTheCapIsSplitAtScalarBoundaries() {
        let text = "x" + "a" + String(repeating: "\u{301}", count: 25) + "y"
        let chunks = TypingChunks.split(text)
        XCTAssertEqual(chunks, [
            "x",
            "a" + String(repeating: "\u{301}", count: 19),
            String(repeating: "\u{301}", count: 6) + "y",
        ])
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= TypingChunks.maxUnits })
        XCTAssertEqual(chunks.joined(), text)
    }

    // A 24-unit single cluster (five-emoji ZWJ family) splits at scalar
    // boundaries too: the first piece carries 20 units, not a torn pair.
    func testABigEmojiClusterIsSplitWithoutTearingAPair() {
        let chunks = TypingChunks.split("👨🏽‍👩🏽‍👧🏽‍👦🏽‍👶🏽")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= TypingChunks.maxUnits })
        XCTAssertEqual(chunks.joined(), "👨🏽‍👩🏽‍👧🏽‍👦🏽‍👶🏽")
        XCTAssertEqual(chunks.first?.utf16.count, TypingChunks.maxUnits)
    }

    // A typed "\n" is a Return — it sends the message in chat apps — so every
    // newline Character (one, even "\r\n") becomes a single space. Dictated
    // text normally has none.
    func testNewlinesBecomeSpaces() {
        XCTAssertEqual(TypingChunks.split("one\ntwo\r\nthree\rfour").joined(), "one two three four")
    }

    // The API contract over a long Russian + emoji text: no chunk over 20
    // UTF-16 units and the text survives whole.
    func testNoChunkExceedsTheApiLimitAndNothingIsLost() {
        let text = "Привет, мир! Диктовка идёт в любое поле — 😀🚀👍🏽 и дальше по-русски."
        let chunks = TypingChunks.split(text + text + text + text)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= TypingChunks.maxUnits })
        XCTAssertEqual(chunks.joined(), text + text + text + text)
    }

    func testEmptyTextHasNoChunks() {
        XCTAssertEqual(TypingChunks.split(""), [])
    }
}
