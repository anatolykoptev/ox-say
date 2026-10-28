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

    /// A snippet is plain speech: shown as it is, so `*` and `_` stay visible and the highlight lands on them, and no
    /// run is a link (nothing is parsed).
    /// Mutation: SearchSnippet.attributed, build from `InlineMarkdown`-less parsing of `[text](url)` (a markdown parse) -> RED.
    func testASnippetIsVerbatimAndHasNoLink() {
        let text = "see [the budget](https://evil.example/x) and *bold* snake_case now"
        let a = SearchSnippet.attributed(text, query: "budget")
        XCTAssertEqual(String(a.characters), text, "nothing is parsed or dropped")
        XCTAssertTrue(a.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(matched(a), ["budget"])
        XCTAssertEqual(matched(SearchSnippet.attributed(text, query: "*bold*")), ["*bold*"])
        XCTAssertEqual(matched(SearchSnippet.attributed(text, query: "snake_case")), ["snake_case"])
    }
}
