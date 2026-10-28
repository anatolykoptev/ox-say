import Foundation
import XCTest
@testable import DictationCore

/// A snippet is what other people said or what a model wrote from it: untrusted text, shown with the match emphasised
/// and never with a link.
final class SearchSnippetTests: XCTestCase {
    private func matched(_ a: AttributedString) -> [String] {
        a.runs.compactMap { run in run.oxsayHighlight == nil ? nil : String(a[run.range].characters) }
    }

    func testTheMatchIsEmphasisedWhateverTheCaseOrYo() {
        let a = SearchSnippet.attributed("…обсудили ёлочные игрушки…", query: "ЕЛОЧНЫЕ")
        XCTAssertEqual(matched(a), ["ёлочные"])
        XCTAssertEqual(String(a.characters), "…обсудили ёлочные игрушки…")
        XCTAssertEqual(matched(SearchSnippet.attributed("Budget, budget", query: "budget")), ["Budget", "budget"])
        XCTAssertEqual(matched(SearchSnippet.attributed("nothing here", query: "zzz")), [])
    }

    /// A link in a snippet is text: no run carries a link, so a click goes nowhere.
    /// Mutation: SearchSnippet.attributed, return the parsed text without `InlineMarkdown.removingLinks` -> RED.
    func testNoLinkInASnippetIsClickable() {
        let a = SearchSnippet.attributed("see [the budget](https://evil.example/x) and <https://evil.example/y> now", query: "budget")
        XCTAssertTrue(a.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(matched(a), ["budget"], "the words of the link are still found and shown")
        XCTAssertFalse(String(a.characters).contains("evil.example/x"), "the address of a markdown link is not shown")
    }
}
