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

    func testARepeatedHeaderAndFooterAreDropped() {
        let bodies = ["Apples grow on trees.", "Pears grow too.", "Plums ripen late.", "Figs need warmth."]
        let pages = bodies.enumerated().map { "Annual Report 2024\n\($0.element)\nAcme Corp — page \($0.offset + 1)" }
        XCTAssertEqual(ScriptCleaner.clean(pages: pages, source: .pdf), bodies.joined(separator: "\n\n"))
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
}
