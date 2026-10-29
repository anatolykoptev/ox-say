import XCTest
@testable import DictationCore

/// #175: lines joined into one paragraph in linear time.
final class PDFTextLayoutScaleTests: XCTestCase {
    /// A paragraph of many lines is built in place: the copying `join` runs only where a paragraph continues on the next
    /// page (once per page break), never once per line (that copied the whole head each time: 9 s for 40 000 lines).
    /// Structural, not timed.
    /// Mutation: PDFTextLayout.pageParagraphs, `append(line, to: &joined)` -> `joined = join(joined, line)` -> RED (joinCalls = lines - 1).
    func testALongParagraphIsBuiltWithoutACopyingJoinPerLine() {
        // Distinct lines of one length: identical pages would lose their repeated edge lines as running header and footer.
        let pages = (0..<3).map { p in (0..<2_000).map { "the quick brown fox jumps over the lazy dog \(p)-\(String(format: "%05d", $0))" }.joined(separator: "\n") }
        PDFTextLayout.joinCalls = 0
        let out = PDFTextLayout.paragraphs(pages)
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 1, "the three pages continue one paragraph")
        XCTAssertTrue(out.contains("2-01999"), "the last line of the last page is in it")
        XCTAssertLessThanOrEqual(PDFTextLayout.joinCalls, 2, "one join per page break, not per line")
    }

    /// The hyphen rules of `join` are unchanged by the in-place build.
    /// Mutation: PDFTextLayout.append, `if first.isLowercase { head.removeLast() }` -> `head.removeLast()` -> RED (Ivanov-Petrov loses its hyphen).
    func testHyphenatedBreaksStillJoinAsBefore() {
        XCTAssertEqual(PDFTextLayout.join("informa-", "tion"), "information")
        XCTAssertEqual(PDFTextLayout.join("Ivanov-", "Petrov"), "Ivanov-Petrov")
        XCTAssertEqual(PDFTextLayout.join("well -", "known"), "well - known")
        XCTAssertEqual(PDFTextLayout.join("a", "b"), "a b")
        XCTAssertEqual(PDFTextLayout.join("-", "x"), "- x")
    }
}
