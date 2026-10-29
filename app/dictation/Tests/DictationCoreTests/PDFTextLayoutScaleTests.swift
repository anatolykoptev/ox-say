import XCTest
@testable import DictationCore

/// #175: a page of very many lines joined into one paragraph in linear time.
final class PDFTextLayoutScaleTests: XCTestCase {
    /// 40 000 lines of one paragraph took about 9 s when every join copied the whole head (as characters); 100 000 lines make even a plain string copy per join take tens of seconds.
    /// Mutation: PDFTextLayout.pageParagraphs, build the paragraph with `joined = join(joined, line)` (a copy of the head per line) -> RED (the time bound).
    func testAPageOfAHundredThousandLinesIsOneParagraphQuickly() {
        let line = "the quick brown fox jumps over the lazy dog again and again today"
        let page = Array(repeating: line, count: 100_000).joined(separator: "\n")
        let started = Date()
        let out = PDFTextLayout.paragraphs([page])
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 1)
        XCTAssertEqual(out.count, 100_000 * (line.count + 1) - 1)
        XCTAssertLessThan(took, 3, "joining 100 000 lines took \(took) s")
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
