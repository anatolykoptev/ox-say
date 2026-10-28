import XCTest
@testable import DictationCore

final class ScriptCleanerTests: XCTestCase {
    /// The daemon's directive pattern, copied from internal/vscript/markup.go:53.
    private let daemonDirective = try! NSRegularExpression(pattern: #"\[([^\[\]\n]*)\]"#)

    private func directives(in text: String) -> [String] {
        let ns = text as NSString
        return daemonDirective.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: PDF layout

    func testAHyphenatedLineBreakIsJoinedLatin() {
        XCTAssertEqual(ScriptCleaner.clean(pages: ["The informa-\ntion is here."], source: .pdf), "The information is here.")
    }

    func testAHyphenatedLineBreakIsJoinedCyrillic() {
        XCTAssertEqual(ScriptCleaner.clean(pages: ["Это важная ин-\nформация для всех."], source: .pdf), "Это важная информация для всех.")
    }

    func testAHyphenBeforeACapitalOrAfterASpaceIsKept() {
        XCTAssertEqual(ScriptCleaner.clean(pages: ["Mr Ivanov-\nPetrov came."], source: .pdf), "Mr Ivanov-Petrov came.")
        XCTAssertEqual(ScriptCleaner.clean(pages: ["He said -\nthen left."], source: .pdf), "He said - then left.")
    }

    func testLinesOfOneParagraphAreJoinedAndBlankLinesKeepParagraphs() {
        let page = "First line of one\nparagraph that wraps.\n\nSecond paragraph\nalso wraps."
        XCTAssertEqual(ScriptCleaner.clean(pages: [page], source: .pdf),
                       "First line of one paragraph that wraps.\n\nSecond paragraph also wraps.")
    }

    func testAPageWithoutBlankLinesEndsAParagraphAfterAShortLine() {
        let long = "This line runs all the way to the right margin of the page"
        let page = [long, long, "and ends here.", long, long].joined(separator: "\n")
        XCTAssertEqual(ScriptCleaner.clean(pages: [page], source: .pdf), "\(long) \(long) and ends here.\n\n\(long) \(long)")
    }

    func testPageNumberLinesAreDropped() {
        let pages = ["Text one.\n\n1", "Text two.\n\n- 2 -", "Text three.\n\nPage 3 of 10", "Text four.\n\nстр. 4"]
        XCTAssertEqual(ScriptCleaner.clean(pages: pages, source: .pdf), "Text one.\n\nText two.\n\nText three.\n\nText four.")
    }

    func testAYearOnItsOwnLineIsNotAPageNumber() {
        XCTAssertEqual(ScriptCleaner.clean(pages: ["It happened in\n\n2024\n\nand again."], source: .pdf),
                       "It happened in\n\n2024\n\nand again.")
    }

    /// A page of `count` distinct body lines between a header and a footer.
    private func longPage(_ index: Int, header: String, footer: String, body count: Int = 8) -> String {
        let body = (1...count).map { "Body line \($0) of leaf \(index) says something different." }
        return ([header] + body + [footer]).joined(separator: "\n")
    }

    func testARepeatedHeaderAndFooterAreDroppedFromLongPages() {
        let pages = (1...4).map { longPage($0, header: "Annual Report 2024", footer: "Acme Corp — page \($0)") }
        let cleaned = ScriptCleaner.clean(pages: pages, source: .pdf)
        XCTAssertFalse(cleaned.contains("Annual Report"))
        XCTAssertFalse(cleaned.contains("Acme Corp"))
        XCTAssertTrue(cleaned.contains("Body line 8 of leaf 4"))
        XCTAssertEqual(cleaned.components(separatedBy: "Body line").count - 1, 32, "every body line is kept")
    }

    func testAHeaderWithAPageNumberInItIsStillRecognised() {
        let pages = (1...4).map { longPage($0, header: "Quarterly Review | \($0)", footer: "\($0) | Acme") }
        let cleaned = ScriptCleaner.clean(pages: pages, source: .pdf)
        XCTAssertFalse(cleaned.contains("Quarterly Review"))
        XCTAssertFalse(cleaned.contains("Acme"))
    }

    func testAChapterHeadingOpeningEachLongPageIsContentNotARunningHeader() {
        let pages = (1...5).map { longPage($0, header: "Chapter \($0)", footer: "end of page") }
        let cleaned = ScriptCleaner.clean(pages: pages, source: .pdf)
        for chapter in 1...5 { XCTAssertTrue(cleaned.contains("Chapter \(chapter)"), "Chapter \(chapter) was dropped") }
        XCTAssertFalse(cleaned.contains("end of page"), "a footer that is identical on every page is still dropped")
    }

    func testShortPagesKeepEveryLineEvenWhenTheyRepeat() {
        let pages = (1...6).map { "Chorus line\nVerse \($0) text goes here and continues.\nChorus line\n\($0)" }
        let cleaned = ScriptCleaner.clean(pages: pages, source: .pdf)
        XCTAssertFalse(cleaned.isEmpty)
        XCTAssertEqual(cleaned.components(separatedBy: "Chorus line").count - 1, 12)
        for verse in 1...6 { XCTAssertTrue(cleaned.contains("Verse \(verse) text goes here and continues.")) }
    }

    func testANumberInTheMiddleOfAPageIsContent() {
        let answer = ScriptCleaner.clean(pages: ["The answer is\n42\nand that is final."], source: .pdf).split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(answer.map(String.init), ["The", "answer", "is", "42", "and", "that", "is", "final."])
        let words = ScriptCleaner.clean(pages: ["Items:\n1\n2\n3\nend"], source: .pdf).split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(words.map(String.init), ["Items:", "1", "2", "3", "end"])
    }

    func testAListOfNumbersOnAPageOfItsOwnIsNotPageNumbers() {
        let words = ScriptCleaner.clean(pages: ["1\n2\n3"], source: .pdf).split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(words.map(String.init), ["1", "2", "3"])
    }

    func testOnlyTheNumberAtTheEdgeOfAPageIsDropped() {
        let pages = ["First line of the page.\nSecond line.\n12\nThird line.\n1", "Fourth line.\n2", "Fifth line.\n3"]
        XCTAssertEqual(ScriptCleaner.clean(pages: pages, source: .pdf).split(whereSeparator: \.isWhitespace).map(String.init),
                       ["First", "line", "of", "the", "page.", "Second", "line.", "12", "Third", "line.", "Fourth", "line.", "Fifth", "line."])
    }

    private func words(_ pages: [String]) -> [String] {
        ScriptCleaner.clean(pages: pages, source: .pdf).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // Mutation: PDFTextLayout.swift, in `dropPageNumbers`, change the evidence guard
    // `sequence.count >= minPagesForPageNumbers` to `sequence.count >= 0` -> RED here
    // (a one-page PDF loses its "4").
    func testANumberAtTheEdgeOfAOnePagePdfIsKept() {
        XCTAssertEqual(words(["Bake until golden.\nServes\n4"]), ["Bake", "until", "golden.", "Serves", "4"])
        XCTAssertEqual(words(["4"]), ["4"])
        XCTAssertEqual(words(["Bake until golden.\nServes\n4", "Second page text."]), ["Bake", "until", "golden.", "Serves", "4", "Second", "page", "text."],
                       "one number on two pages is still one number")
    }

    func testPageNumbersRisingFromPageToPageAreDroppedOnAFivePagePdf() {
        let bottom = (1...5).map { "Page \($0) text goes here.\n\($0)" }
        XCTAssertEqual(words(bottom), (1...5).flatMap { ["Page", "\($0)", "text", "goes", "here."] })
        let top = (1...5).map { "\($0)\nPage \($0) text goes here." }
        XCTAssertEqual(words(top), words(bottom))
        let gaps = ["One.\n1", "Two.\n2", "Three is a picture.", "Four.\n4", "Five.\n5"]
        XCTAssertEqual(words(gaps), ["One.", "Two.", "Three", "is", "a", "picture.", "Four.", "Five."])
    }

    // Mutation: PDFTextLayout.swift, in `dropPageNumbers`, group every candidate into ONE sequence (`by: { _ in 0 }`)
    // -> RED here (the numbers that do not go on as the pages do are dropped as well).
    func testNumbersThatDoNotRiseAreText() {
        XCTAssertEqual(words(["Final score.\n10", "Two.\n3", "Three.\n4", "Four.\n5"]), ["Final", "score.", "10", "Two.", "Three.", "Four."])
        XCTAssertEqual(words(["A.\n4", "B.\n4"]), ["A.", "4", "B.", "4"], "equal numbers do not rise")
        XCTAssertEqual(words(["A.\n7", "B.\n3"]), ["A.", "7", "B.", "3"])
    }

    func testALineThatRepeatsOnFewPagesIsKept() {
        let pages = ["Chapter One\nBody a.", "Body b.", "Body c.", "Body d."]
        XCTAssertTrue(ScriptCleaner.clean(pages: pages, source: .pdf).contains("Chapter One"))
    }

    func testAParagraphContinuesOverAPageBreak() {
        XCTAssertEqual(ScriptCleaner.clean(pages: ["The sentence begins on one", "page and ends on the next."], source: .pdf),
                       "The sentence begins on one page and ends on the next.")
        XCTAssertEqual(ScriptCleaner.clean(pages: ["It ends here.", "Next page starts."], source: .pdf),
                       "It ends here.\n\nNext page starts.")
    }

    // MARK: brackets

    func testFootnoteMarkersAreRemoved() {
        XCTAssertEqual(ScriptCleaner.clean("Water boils[1] at 100 degrees [2, 3]. See also [4-6]."), "Water boils at 100 degrees. See also.")
    }

    func testOtherBracketsLoseTheirBracketsAndKeepTheirWords() {
        XCTAssertEqual(ScriptCleaner.clean("He wrote [sic] a word [music]. And [Editor's note: see below]."),
                       "He wrote sic a word music. And Editor's note: see below.")
    }

    func testNoDirectiveReachesTheDaemonFromADocument() {
        let hostile = "Intro [pause 2s] text [style: angry] more [unknown] [pause 99s] [a\nb] [[nested]] ] [ end"
        for source in [ScriptCleaner.Source.richText, .pdf] {
            XCTAssertEqual(directives(in: ScriptCleaner.clean(pages: [hostile], source: source)), [], "\(source)")
        }
        XCTAssertFalse(ScriptCleaner.clean(hostile, source: .richText).contains("["))
    }

    func testAPdfLineBreakCannotJoinTwoHalvesIntoADirective() {
        let cleaned = ScriptCleaner.clean(pages: ["Open [music\nplays] closed."], source: .pdf)
        XCTAssertEqual(directives(in: cleaned), [])
        XCTAssertFalse(cleaned.contains("["))
    }

    func testAScriptTheOwnerWroteKeepsTheDirectivesTheDaemonAccepts() {
        let script = "[style: calm and warm]\nHello there. [pause 0.6s] More text. [pause 500ms]\n\nSecond [pause] one."
        XCTAssertEqual(ScriptCleaner.clean(script), "[style: calm and warm]\nHello there. [pause 0.6s] More text. [pause 500ms]\n\nSecond [pause] one.")
    }

    func testDirectivesTheDaemonWouldRejectAreNeutralisedInAScriptToo() {
        let script = "[pause 1s] Start. [pause 0.01s] [pause 11s] [music] mid [style: late] end\n\n[style: ]\nText.\n\n[style: ()]\nMore."
        let cleaned = ScriptCleaner.clean(script)
        XCTAssertEqual(directives(in: cleaned), [], cleaned)
    }

    func testAStyleStaysOnlyAtTheStartOfAParagraphWithTextAfterIt() {
        XCTAssertEqual(directives(in: ScriptCleaner.clean("[style: calm]\nText.")), ["[style: calm]"])
        XCTAssertEqual(directives(in: ScriptCleaner.clean("[style: calm]")), [])
        XCTAssertEqual(directives(in: ScriptCleaner.clean("Text. [style: calm] more")), [])
    }

    func testAPauseNeedsSpokenTextBeforeIt() {
        XCTAssertEqual(directives(in: ScriptCleaner.clean("Text first. [pause 1s] more")), ["[pause 1s]"])
        XCTAssertEqual(directives(in: ScriptCleaner.clean("[pause 1s] text")), [])
        XCTAssertEqual(directives(in: ScriptCleaner.clean("[style: calm]\n[pause 1s] text")), ["[style: calm]"])
    }

    // MARK: paragraphs, white space, idempotence

    func testParagraphsAreKeptAndWhiteSpaceIsFolded() {
        XCTAssertEqual(ScriptCleaner.clean("  One\u{00A0}\u{00A0}two \t three  \r\n\r\n\r\n\r\n  Next\u{200B} para.  \r\n"),
                       "One two three\n\nNext para.")
    }

    func testRichTextEveryLineBreakIsAParagraphBreak() {
        XCTAssertEqual(ScriptCleaner.clean("Title\nFirst para.\n\u{FFFC}\nSecond para.", source: .richText), "Title\n\nFirst para.\n\nSecond para.")
    }

    func testAParagraphThatWasOnlyAFootnoteLeavesNoGap() {
        XCTAssertEqual(ScriptCleaner.clean("Hello[1]\n\n[2]\n\nWorld"), "Hello\n\nWorld")
        XCTAssertEqual(ScriptCleaner.clean("A\n\n[ ]\n\nB"), "A\n\nB")
    }

    func testCleaningTwiceChangesNothing() {
        let samples: [(String, ScriptCleaner.Source)] = [
            ("[style: calm]\nHi [1] there. [pause 2s]\n\n\nTwo [music] [x\ny] \u{00A0} ok", .text),
            ("Word line one\nline two [3]\n\n[pause 1s] x", .richText),
        ]
        for (text, source) in samples {
            let once = ScriptCleaner.clean(text, source: source)
            XCTAssertEqual(ScriptCleaner.clean(once, source: source), once, "\(source)")
        }
        let pages = (1...4).map { "Header\nThe informa-\ntion of page \($0) [1].\nAnother line.\n\($0)" }
        let once = ScriptCleaner.clean(pages: pages, source: .pdf)
        XCTAssertEqual(ScriptCleaner.clean(pages: [once], source: .pdf), once)
    }

    // MARK: Markdown

    private func markdown(_ text: String) -> String { ScriptCleaner.clean(text, source: .markdown) }

    func testAMarkdownLinkIsReadAsItsText() {
        XCTAssertEqual(markdown("See [the docs](https://example.com/a?b=1&c=2) now."), "See the docs now.")
        XCTAssertEqual(markdown("A [page](https://en.wikipedia.org/wiki/Foo_(bar) \"Title\") here."), "A page here.")
    }

    func testAMarkdownImageIsReadAsItsAltTextOrNothing() {
        XCTAssertEqual(markdown("Before ![a red door](door.png) after."), "Before a red door after.")
        XCTAssertEqual(markdown("Before ![](door.png) after."), "Before after.")
    }

    func testABadgeThatIsALinkAroundAnImageIsReadAsItsAlt() {
        XCTAssertEqual(markdown("[![build status](https://ci.example/badge.svg)](https://ci.example)"), "build status")
        XCTAssertEqual(markdown("[![](https://ci.example/badge.svg)](https://ci.example)"), "")
    }

    func testReferenceLinksAreReadAsTheirTextAndTheirDefinitionsGo() {
        let text = "Read [the guide][guide] and [the FAQ][] and [docs][1].\n\n[guide]: https://example.com/guide \"Guide\"\n[the FAQ]: <https://example.com/faq>\n[1]: https://example.com/1"
        XCTAssertEqual(markdown(text), "Read the guide and the FAQ and docs.")
    }

    func testAutolinksAreRemoved() {
        XCTAssertEqual(markdown("Mail <me@example.com> or visit <https://example.com/x>."), "Mail or visit.")
    }

    func testTaskListBoxesAreRemoved() {
        XCTAssertEqual(markdown("- [ ] buy milk\n- [x] done\n  * [X] nested"), "- buy milk\n- done\n* nested")
    }

    func testTheDaemonsDirectivesStillWorkInAMarkdownFile() {
        let text = "[style: calm] Hello [pause 1s] and [link](http://x.y) more.\n\nSecond [pause 2s] paragraph."
        XCTAssertEqual(markdown(text), "[style: calm] Hello [pause 1s] and link more.\n\nSecond [pause 2s] paragraph.")
    }

    func testALinkWhoseTextLooksLikeADirectiveIsNotADirective() {
        XCTAssertEqual(markdown("Wait [pause 1s](https://x.y) here."), "Wait pause 1s here.")
    }

    func testAPlainTextFileIsNotReadAsMarkdown() {
        XCTAssertEqual(ScriptCleaner.clean("See [the docs](https://example.com/a) now.", source: .text), "See the docs (https://example.com/a) now.")
    }

    func testMarkdownCleaningIsIdempotent() {
        let once = markdown("# T\n\nSee [a](u) ![b](v) <https://x.y>\n\n- [x] k\n\n[r]: http://r")
        XCTAssertEqual(markdown(once), once)
    }

    /// A run of spaces this long made the old autolink rule take 12.7 s (every start in
    /// the run scanned the rest of it); a linear rule takes a few milliseconds.
    private static let spaceRunLength = 40_000
    private static let maxSecondsForTheSpaceRun = 1.0

    // Mutation: MarkdownText.swift, in `autolinkBeforePunctuation`, put `[ \t]*`
    // back in front of the autolink -> RED (the run of spaces takes seconds).
    func testAnAutolinkAfterAHugeRunOfSpacesIsCleanedInLinearTime() {
        // The autolink is not followed by punctuation, so a rule that starts with the
        // spaces fails at every start in the run before the plain rule removes it.
        let text = "Visit" + String(repeating: " ", count: Self.spaceRunLength) + "<https://example.com/x> Done."
        let started = Date()
        let result = markdown(text)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(result, "Visit Done.")
        XCTAssertLessThan(seconds, Self.maxSecondsForTheSpaceRun, "the autolink rule backtracks on a run of spaces")
    }

    // Mutation: MarkdownText.swift, in `destination`, put `\S*/\S*` back in place of
    // `[^\s/]*/\S*` -> RED (a 40 000-slash token then a word took 36 s).
    func testADefinitionWithAHugeSlashTokenIsCleanedInLinearTime() {
        // The token is not the whole line, so the rule fails after trying every way to split it.
        let text = "[a]: " + String(repeating: "/", count: Self.spaceRunLength) + " x"
        let started = Date()
        let result = markdown(text)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertTrue(result.hasPrefix("a: /"), "a line with a stray word after the address is speech and stays")
        XCTAssertLessThan(seconds, Self.maxSecondsForTheSpaceRun, "the definition rule backtracks on a long run of slashes")
    }

    func testADefinitionWithAHugeTokenOfSlashSegmentsIsCleanedInLinearTime() {
        let text = "[a]: " + String(repeating: "a/", count: Self.spaceRunLength / 2) + " x"
        let started = Date()
        let result = markdown(text)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertTrue(result.hasPrefix("a: a/"), "a line with a stray word after the address is speech and stays")
        XCTAssertLessThan(seconds, Self.maxSecondsForTheSpaceRun, "the definition rule backtracks on a long run of slash segments")
    }

    // Mutation: MarkdownText.swift, in `footnoteMark`, put `[ \t]*` in front of the
    // pattern -> RED. The text after the spaces is not a complete mark, so a rule
    // that starts with the spaces fails at every start in the run.
    func testAFootnoteMarkRuleDoesNotBacktrackOnARunOfSpaces() {
        let text = "Note" + String(repeating: " ", count: Self.spaceRunLength) + "[^1 and more."
        let started = Date()
        let result = markdown(text)
        XCTAssertEqual(result, markdown("Note [^1 and more."))
        XCTAssertLessThan(Date().timeIntervalSince(started), Self.maxSecondsForTheSpaceRun)
    }

    // Mutation: MarkdownText.swift, in `definitionRules`, put the old pattern back:
    // `^ {0,3}\[[^\[\]\n]+\]:[ \t]*\S.*\n?` -> RED here (the Narrator line is deleted).
    func testALineThatLooksLikeADefinitionButIsSpeechIsKept() {
        XCTAssertEqual(markdown("[Narrator]: Once upon a time…"), "Narrator: Once upon a time…")
        XCTAssertEqual(markdown("He said:\n[note]: this is a quote line\nmore"), "He said:\nnote: this is a quote line\nmore")
        XCTAssertEqual(markdown("[todo]: hello"), "todo: hello", "one plain word is not an address")
    }

    func testOnlyALineThatIsAnAddressIsADefinition() {
        let text = "Body.\n\n[a]: https://example.com/a\n[b]: /local/path 'Title'\n[c]: <#frag> (Title)\n[d]: www.example.com\n[e]: images/pic.png \"Pic\""
        XCTAssertEqual(markdown(text), "Body.")
    }

    // Footnote marks are not speech and are removed from every source (`[1]`); the
    // notes they point to are page-bottom asides for the eye, which read aloud after
    // the body, or in the middle of it, would only confuse a listener. Both go.
    func testFootnoteMarksAndTheirDefinitionsAreDropped() {
        let text = "Text[^1] and more.[^note] Again [^1].\n\n[^1]: The note text.\n    It goes on here.\n[^note]: Another."
        XCTAssertEqual(markdown(text), "Text and more. Again.")
        XCTAssertEqual(markdown("Two[^1][^2] marks."), "Two marks.")
    }

    // MARK: #175 leftovers

    // Mutation: PDFTextLayout.swift, in `dropPageNumbers`, keep only the first sequence (`.prefix(1)` on
    // `sequences.values`) -> RED (one numbering's digits stay as stray digits).
    func testRestartedPageNumberingIsDroppedRunByRun() {
        let front = (1...3).map { "Preface text \($0) goes here.\n\($0)" }
        let body = (1...4).map { "Body text \($0) goes here.\n\($0)" }
        let expected = (1...3).flatMap { ["Preface", "text", "\($0)", "goes", "here."] } + (1...4).flatMap { ["Body", "text", "\($0)", "goes", "here."] }
        XCTAssertEqual(words(front + body), expected)
    }

    // #175 — a chapter number opening each page is text. Three chapters of three pages each print "1" on pages 1-3,
    // "2" on pages 4-6, "3" on pages 7-9: the numbers rise, but they repeat on consecutive pages, so they are not a
    // page-number sequence.
    // Mutation: PDFTextLayout.swift, in `dropPageNumbers`, delete the `repeats` filter -> RED here (and the
    // chapter numbers vanish from the spoken text).
    func testAChapterNumberRepeatedOnConsecutivePagesIsKept() {
        let pages = (0..<9).map { "\($0 / 3 + 1)\nChapter page \($0) text goes here." }
        XCTAssertEqual(words(pages), (0..<9).flatMap { ["\($0 / 3 + 1)", "Chapter", "page", "\($0)", "text", "goes", "here."] })
    }

    // #175 — numbers that rise but not as the pages do (a chapter number on the first page of each chapter only) are
    // not a page-number sequence either: page 1, 4, 7 print 1, 2, 3.
    // Mutation: PDFTextLayout.swift, in `dropPageNumbers`, group the candidates by `_ in 0` (one sequence)
    // instead of `value - page` -> RED here.
    func testNumbersThatRiseSlowerThanThePagesAreKept() {
        let pages = (0..<9).map { $0 % 3 == 0 ? "\($0 / 3 + 1)\nChapter page text goes here." : "Chapter page text goes here." }
        let spoken = words(pages)
        XCTAssertEqual(spoken.filter { ["1", "2", "3"].contains($0) }, ["1", "2", "3"], "a chapter number was dropped as a page number")
        XCTAssertEqual(spoken.count, 9 * 5 + 3)
    }

    // #175 — a long PDF with a real page number on every page is still cleaned (the grouping is one pass).
    func testAHundredPagesOfPageNumbersAreAllDropped() {
        let pages = (1...120).map { "Page body \($0) goes here.\n\($0)" }
        XCTAssertEqual(words(pages), (1...120).flatMap { ["Page", "body", "\($0)", "goes", "here."] })
    }

    // Mutation: MarkdownText.swift, `bracketed` -> `[^\[\]\n]*` (no nesting) -> RED
    // (the address is spoken).
    func testALinkWhoseTextHoldsBracketsIsReadAsItsText() {
        XCTAssertEqual(markdown("See [the docs [beta]](https://example.com/a) now."), "See the docs beta now.")
        XCTAssertEqual(markdown("![chart [fig 2]](img/a.png) end"), "chart fig 2 end")
    }

    // Mutation: MarkdownText.swift, in `plain`, return `clean(text)` before the code
    // spans are held aside -> RED (the example's link syntax is stripped to "text").
    // The brackets that remain are neutralised later by the directive rules, as for any text.
    func testCodeIsSpokenAsWritten() {
        XCTAssertEqual(markdown("Write `[text](url)` for a link, then [the docs](https://example.com)."),
                       "Write ` text (url)` for a link, then the docs.")
        XCTAssertEqual(markdown("Example:\n```\n[a](b) <b>x</b>\n```\nDone [c](d)."), "Example:\n```\na (b) <b>x</b>\n```\nDone c.")
    }

    // Mutation: MarkdownText.swift, in `clean`, skip `stripHTML` -> RED.
    func testRawInlineHtmlIsNotSpoken() {
        XCTAssertEqual(markdown("A <b>bold</b> move<br>and <span class=\"x\">more</span><!-- note --> here."), "A bold move\nand more here.")
        XCTAssertEqual(markdown("When a < b and c > d, mail <me@example.com>."), "When a < b and c > d, mail.")
    }
}
