import Foundation

/// Cleans the text of a document into a script the daemon accepts. Pure: every
/// source (text, Markdown, Word, a PDF) goes through it before the person sees it.
///
/// A script is paragraphs separated by one blank line; the daemon pauses between
/// them. The cleaner keeps those, folds all other white space, and takes out what
/// is layout rather than speech (see PDFTextLayout) and the square brackets the
/// daemon would read as directives (see ScriptBrackets).
public enum ScriptCleaner {
    public enum Source: Equatable {
        /// A text file the owner wrote: line breaks stay as written and the
        /// `[pause]` / `[style:]` directives the daemon accepts stay.
        case text
        /// A Markdown file (by its extension, never guessed from the content): as
        /// `.text`, with links, images and task boxes reduced to the words (see MarkdownText).
        case markdown
        /// Word, RTF, ODT: every line break ends a paragraph.
        case richText
        /// PDF pages: paragraphs are inferred from the layout.
        case pdf
    }

    public static func clean(_ text: String, source: Source = .text) -> String {
        clean(pages: [text], source: source)
    }

    /// `pages` matter for a PDF (a repeated header is found across pages); the
    /// other sources are one text.
    public static func clean(pages: [String], source: Source) -> String {
        let normal = pages.map { source == .markdown ? MarkdownText.plain(normalise($0)) : normalise($0) }
        let body: String
        switch source {
        case .text, .markdown: body = normal.joined(separator: "\n\n")
        case .richText: body = normal.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n\n")
        case .pdf: body = PDFTextLayout.paragraphs(normal)
        }
        let folded = foldWhitespace(body)
        return foldWhitespace(ScriptBrackets.neutralise(folded, keepDirectives: source == .text || source == .markdown))
    }

    /// Line endings become "\n"; invisible characters go; every kind of space
    /// becomes a plain one.
    static func normalise(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for u in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            switch u {
            case "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}": out.append("\n")
            case "\u{2029}": out.append(contentsOf: "\n\n".unicodeScalars)
            case "\u{AD}", "\u{200B}", "\u{2060}", "\u{FEFF}", "\u{FFFC}": continue
            case "\n": out.append(u)
            default:
                let category = u.properties.generalCategory
                out.append(category == .spaceSeparator || category == .control ? " " : u)
            }
        }
        return String(out)
    }

    /// Runs of spaces become one, lines are trimmed, a run of blank lines becomes
    /// one blank line, and the ends are trimmed. Idempotent.
    static func foldWhitespace(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
