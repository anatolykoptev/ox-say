import XCTest
@testable import DictationCore

final class ScriptLimitTests: XCTestCase {
    private func paragraphs(_ unit: String, each: Int, count: Int) -> String {
        Array(repeating: String(repeating: unit, count: each), count: count).joined(separator: "\n\n")
    }

    func testTheLengthIsCountedInRunesAsTheDaemonCountsThem() {
        XCTAssertEqual(ScriptLimit.count("я"), 1)
        XCTAssertEqual(ScriptLimit.count("😀"), 1, "one rune, two UTF-16 units")
        XCTAssertEqual(ScriptLimit.count("е\u{0301}"), 2, "one Character, two runes")
    }

    func testTheTrimCutsAtAParagraphBoundaryUnderTheLimit() {
        let text = paragraphs("a", each: 10, count: 3) // 10 + 2 + 10 + 2 + 10
        XCTAssertEqual(ScriptLimit.keepFirstPart(text, limit: 25), paragraphs("a", each: 10, count: 2))
        XCTAssertEqual(ScriptLimit.keepFirstPart(text, limit: 22), paragraphs("a", each: 10, count: 2), "a break exactly at the limit still fits")
        XCTAssertEqual(ScriptLimit.keepFirstPart(text, limit: 21), String(repeating: "a", count: 10))
    }

    func testATextThatFitsIsKept() {
        XCTAssertEqual(ScriptLimit.keepFirstPart("  Short.\n\nText.  "), "Short.\n\nText.")
    }

    func testTheTrimMeasuresInRunesNotUtf16Units() {
        // Emoji are two UTF-16 units and one rune: three paragraphs of 10 emoji are
        // 34 runes and 64 units. A UTF-16 count would stop after the first one.
        let text = paragraphs("😀", each: 10, count: 3)
        let part = ScriptLimit.keepFirstPart(text, limit: 34)
        XCTAssertEqual(part, text)
        XCTAssertEqual(ScriptLimit.keepFirstPart(text, limit: 33), paragraphs("😀", each: 10, count: 2))
    }

    func testTheTrimMeasuresRunesNotCharacters() {
        // "е" + combining acute is one Character and two runes. Counted as Characters
        // the third paragraph would seem to fit; the daemon would see 34 runes.
        let text = paragraphs("е\u{0301}", each: 5, count: 3)
        let part = ScriptLimit.keepFirstPart(text, limit: 25)
        XCTAssertLessThanOrEqual(ScriptLimit.count(part), 25)
        XCTAssertEqual(part, paragraphs("е\u{0301}", each: 5, count: 2))
    }

    func testTheResultIsUnderTheRealLimitAsTheDaemonCountsIt() {
        let text = paragraphs("я😀", each: 300, count: 200)
        let part = ScriptLimit.keepFirstPart(text)
        XCTAssertLessThanOrEqual(part.unicodeScalars.count, ScriptLimit.maxCharacters)
        XCTAssertGreaterThan(part.unicodeScalars.count, ScriptLimit.maxCharacters - 602, "the last paragraph that fits is kept")
        XCTAssertTrue(ScriptLimit.canStart(editorText: part))
    }

    func testAFirstParagraphThatIsTooLongIsCutAtASentenceThenASpace() {
        let sentences = "One sentence here. Another sentence here. Third sentence here."
        XCTAssertEqual(ScriptLimit.keepFirstPart(sentences, limit: 45), "One sentence here. Another sentence here.")
        XCTAssertEqual(ScriptLimit.keepFirstPart("alpha beta gamma delta", limit: 14), "alpha beta")
        XCTAssertEqual(ScriptLimit.keepFirstPart("abcdefghij", limit: 4), "abcd")
    }

    func testTheStatusLineSaysSizeMinutesAndOverrun() {
        XCTAssertEqual(ScriptLimit.statusLine(editorText: ""), "There is no text to read yet.")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: " \n "), "There is no text to read yet.")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: "Hello."), "6 characters · about 1 minute")
        XCTAssertEqual(ScriptLimit.statusLine(editorText: String(repeating: "я", count: 8340)), "8340 characters · about 10 minutes")
        let over = String(repeating: "я", count: ScriptLimit.maxCharacters + 7)
        XCTAssertTrue(ScriptLimit.statusLine(editorText: over).contains("7 over the limit"))
        XCTAssertFalse(ScriptLimit.canStart(editorText: over))
        XCTAssertTrue(ScriptLimit.canStart(editorText: String(repeating: "я", count: ScriptLimit.maxCharacters)))
    }

    func testTheLimitIsMeasuredOnWhatIsSentNotOnTheWhiteSpaceAroundIt() {
        let body = String(repeating: "я", count: ScriptLimit.maxCharacters)
        XCTAssertTrue(ScriptLimit.canStart(editorText: "\n\n" + body + "  \n"))
    }
}
