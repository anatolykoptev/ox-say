import Foundation

/// The text a person sees in an HTML page, read from the page's tree and nothing
/// else. The tree comes from Foundation's HTML parser, which only parses: it
/// loads no image, style sheet, frame or DTD, whatever the page links to. An
/// HTML importer that renders the page (WebKit behind NSAttributedString) does
/// load them, from any attribute that holds a URL, and a list of tags to strip
/// cannot be complete; this reads text nodes, so there is nothing to strip.
enum HTMLText {
    /// Elements whose content is not text the reader sees: the head with its
    /// title, code, or a fallback for something that is not shown.
    static let skipped: Set<String> = ["head", "script", "style", "noscript", "iframe", "object", "embed", "applet", "select"]
    /// Elements that start a new line (a paragraph, to the script) before and after.
    static let blocks: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl", "dt", "dd", "tr", "table",
        "blockquote", "section", "article", "aside", "header", "footer", "main", "nav", "figure", "figcaption",
        "pre", "hr", "form", "fieldset", "address", "details", "summary", "body", "html",
    ]
    /// A break inside a block: the next text starts a new line.
    private static let lineBreak = "br"
    /// Table cells are told apart by a space, not a line.
    private static let cells: Set<String> = ["td", "th"]
    /// Its line breaks are kept as written.
    private static let preformattedTag = "pre"
    /// HTML white space: it collapses to one space (a no-break space does not).
    private static let htmlSpace = CharacterSet(charactersIn: " \t\r\n\u{0C}")

    /// How the parser reads the page: repairing it the way a browser would, and
    /// never fetching an external entity or DTD.
    private static let parseOptions: XMLNode.Options = [.documentTidyHTML, .nodeLoadExternalEntitiesNever]

    /// Elements the parser's repair step discards by name (it predates HTML5) and
    /// leaves their content in the body: their content is not text the reader
    /// sees, so it is cut out before parsing.
    private static let removedBeforeParsing = try! NSRegularExpression(
        pattern: #"<(template|svg|math|video|audio|canvas)\b.*?</\1\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    /// HTML5 sectioning elements, which the same step discards and would run into
    /// the text around them; they are read as the blocks they are.
    private static let sectioning = try! NSRegularExpression(
        pattern: #"<(/?)(?:section|article|nav|header|footer|main|aside|figure|figcaption|details|summary|hgroup|dialog)\b"#,
        options: .caseInsensitive)

    /// nil when the parser cannot make a tree of the page at all.
    static func plain(_ html: String) -> String? {
        let prepared = prepare(html)
        // A text with no tag at all is not a document to the parser; as a body it is.
        guard let root = tree(prepared) ?? tree("<body>\(prepared)</body>") else { return nil }
        var out = ""
        append(root, to: &out, preformatted: false)
        return out
    }

    private static func tree(_ html: String) -> XMLElement? {
        (try? XMLDocument(xmlString: html, options: parseOptions))?.rootElement()
    }

    private static func prepare(_ html: String) -> String {
        let whole = NSRange(html.startIndex..., in: html)
        let kept = removedBeforeParsing.stringByReplacingMatches(in: html, range: whole, withTemplate: " ")
        return sectioning.stringByReplacingMatches(in: kept, range: NSRange(kept.startIndex..., in: kept), withTemplate: "<$1div")
    }

    private static func append(_ node: XMLNode, to out: inout String, preformatted: Bool) {
        switch node.kind {
        case .text:
            let text = node.stringValue ?? ""
            out += preformatted ? text : collapsed(text)
        case .element:
            let name = (node.name ?? "").lowercased()
            if skipped.contains(name) { return }
            if name == lineBreak {
                out += "\n"
                return
            }
            let isBlock = blocks.contains(name)
            if isBlock { out += "\n" }
            let keepsLines = preformatted || name == preformattedTag
            for child in node.children ?? [] { append(child, to: &out, preformatted: keepsLines) }
            if isBlock { out += "\n" } else if cells.contains(name) { out += " " }
        default:
            return
        }
    }

    /// Runs of HTML white space become one space.
    private static func collapsed(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inSpace = false
        for scalar in text.unicodeScalars {
            if htmlSpace.contains(scalar) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(scalar)
                inSpace = false
            }
        }
        return String(out)
    }
}
