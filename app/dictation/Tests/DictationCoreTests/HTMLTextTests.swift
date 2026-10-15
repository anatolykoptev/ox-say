import XCTest
@testable import DictationCore

/// The text of a page read from its parsed tree, through the cleaner as a document is.
final class HTMLTextTests: XCTestCase {
    private func script(_ html: String) -> String {
        ScriptCleaner.clean(HTMLText.plain(html) ?? "(the page did not parse)", source: .richText)
    }

    func testBlockElementsAndLineBreaksBecomeParagraphs() {
        let html = "<h1>Title</h1><p>One<br>two</p><div>Three</div><ul><li>a</li><li>b</li></ul><blockquote>Quote</blockquote>"
        XCTAssertEqual(script(html), "Title\n\nOne\n\ntwo\n\nThree\n\na\n\nb\n\nQuote")
    }

    func testInlineElementsStayInTheirSentence() {
        XCTAssertEqual(script("<p>First <b>bold</b>, <i>it</i>alic and <a href=\"x\">a link</a>.</p>"),
                       "First bold, italic and a link.")
    }

    func testTableRowsAreLinesAndCellsShareOne() {
        XCTAssertEqual(script("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"), "a b\n\nc d")
    }

    func testHeadScriptsStylesAndOtherInvisibleContentAreSkipped() {
        let html = """
        <html><head><title>Page title</title><style>p{color:red}</style></head><body>
        <script>var a = "[pause]";</script><noscript>Enable JS</noscript><template><p>tpl</p></template>
        <svg><text>vector</text></svg><iframe>frame fallback</iframe><p>Kept.</p><!-- comment --></body></html>
        """
        XCTAssertEqual(script(html), "Kept.")
    }

    func testHtml5SectionsAreParagraphsAndMediaFallbacksAreSkipped() {
        let html = """
        <header>Head</header><nav>Menu</nav><main><article><section>A</section><section>B</section></article></main>
        <figure><figcaption>Caption</figcaption></figure><aside>Side</aside><footer>Foot</footer>
        <video>no video</video><audio>no audio</audio><canvas>no canvas</canvas><svg><text>vector</text></svg><math><mi>x</mi></math>
        """
        XCTAssertEqual(script(html), "Head\n\nMenu\n\nA\n\nB\n\nCaption\n\nSide\n\nFoot")
    }

    func testAnUnclosedScriptTakesNothingIntoTheText() {
        XCTAssertFalse(script("<p>Before</p><script>alert(1)<p>after the script</p>").contains("alert"))
    }

    func testEntitiesAreDecodedAndWhiteSpaceCollapses() {
        XCTAssertEqual(script("<p>Tom &amp; Jerry&nbsp;&mdash;\n   &lt;done&gt;  &copy;</p>"), "Tom & Jerry — <done> ©")
    }

    func testCyrillicIsReadWhateverTheMetaTagClaims() {
        XCTAssertEqual(script("<html><head><meta charset=\"windows-1251\"></head><body><p>Привет, мир.</p></body></html>"), "Привет, мир.")
    }

    func testPreformattedTextKeepsItsLines() {
        XCTAssertEqual(script("<pre>line one\nline two</pre>"), "line one\n\nline two")
    }

    func testTextWithoutAnyTagIsStillText() {
        XCTAssertEqual(script("just words"), "just words")
    }
}
