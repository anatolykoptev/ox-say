import Foundation

/// What a Markdown file says aloud: the words, without the syntax that points
/// elsewhere. A link is read as its text and an image as its alt text; the
/// address is for the eye. Runs before the bracket rules, so `[text](url)` never
/// reaches them as a bracket pair, and the daemon's own `[pause 1s]` and
/// `[style: calm]` (a pair with no `(` or `[` right after it) pass through.
enum MarkdownText {
    /// A bracketed address: `(url)`, `(url "title")`, one level of nested parentheses in the url.
    private static let target = #"\((?:[^()\n]|\([^()\n]*\))*\)"#

    /// Link text: no brackets, or one level of them.
    private static let bracketed = #"(?:[^\[\]\n]|\[[^\[\]\n]*\])*"#

    /// Raw inline HTML that formats or lays out text, a line break, and comments.
    /// Only named tags: `a < b` and `<name@host>` are not tags.
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"</?(?:a|abbr|b|big|blockquote|center|cite|code|dd|del|details|div|dl|dt|em|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|q|s|small|span|strike|strong|sub|summary|sup|table|tbody|td|tfoot|th|thead|tr|u|ul)(?:\s[^<>\n]*)?/?>"#,
        options: .caseInsensitive)
    private static let htmlBreak = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: .caseInsensitive)
    private static let htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

    /// Code the rules must not read: a fenced block (an unterminated fence is not one) and an inline span.
    private static let codeSpan = try! NSRegularExpression(
        pattern: #"^ {0,3}```[^\n]*\n(?:[^\n]*\n)*? {0,3}```[ \t]*$|(?<!`)(`+)(?!`)[^\n]*?(?<!`)\1(?!`)"#,
        options: [.anchorsMatchLines])
    private static let codeOpen = "\u{E000}", codeClose = "\u{E001}"

    private static let autolink = #"<(?:(?:https?|ftp|mailto):[^<>\s]*|[^<>\s@]+@[^<>\s]+)>"#

    /// What a reference definition may point at: `<anything>`, a URL with a scheme,
    /// `www.`, an absolute or dot-relative path, a `#fragment`, or any path with a
    /// slash in it (`[^\s/]*/\S*`: the first slash ends the first piece, so a
    /// long token is not split at every slash). A plain word is not an address, so `[Narrator]: Once upon a
    /// time` and `[note]: this is a quote line` are spoken lines and stay.
    private static let destination = #"(?:<[^<>\s]+>|[A-Za-z][A-Za-z0-9+.-]*://\S+|mailto:\S+|www\.\S+|[./#]\S*|[^\s/]*/\S*)"#
    /// An optional title after the address: "…", '…' or (…).
    private static let title = #"(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?"#

    /// Applied in this order; each is `(pattern, template, options)`.
    private static let definitionRules = compiled([
        // `[^1]: note` footnote definitions, whole lines and their indented continuation lines.
        (#"^ {0,3}\[\^[^\[\]\s]+\]:.*(?:\n(?: {4}|\t).*)*\n?"#, "", [.anchorsMatchLines]),
        // `[ref]: url "title"` definitions, whole lines, and only when the line is an address.
        (#"^ {0,3}\[[^\[\]\n]+\]:[ \t]*\#(destination)\#(title)[ \t]*(?:\n|\z)"#, "", [.anchorsMatchLines]),
    ])

    private static let inlineRules = compiled([
        // `- [ ] item` and `- [x] item`: the box is not speech.
        (#"^([ \t]*[-*+][ \t]+)\[[ xX]\][ \t]+"#, "$1", [.anchorsMatchLines]),
        // `![alt](url)` and `![alt][ref]`: the alt text, or nothing. The text may hold one level of brackets.
        (#"!\[(\#(bracketed))\](?:\#(target)|\[[^\[\]\n]*\])"#, "$1", []),
        // `[text](url)`; the text may hold one level of brackets (`[see [1]](url)`).
        (#"\[(\#(bracketed))\]\#(target)"#, "$1", []),
        // `[text][ref]` and `[text][]`, unless the text starts with a digit: `[1][2]` are two footnote marks.
        (#"\[([^\[\]\n0-9][^\[\]\n]*)\]\[[^\[\]\n]*\]"#, "$1", []),
    ])

    /// A footnote mark `[^1]` is removed with the spaces before it, ahead of the
    /// link rules (`[^1][^2]` is two marks, not a reference link). An autolink
    /// before the punctuation that ends a phrase goes with the spaces before it.
    /// No pattern may start with `[ \t]*`: on a long run of spaces the matcher would
    /// try every start in the run and scan the rest of it each time.
    private static let footnoteMark = try! NSRegularExpression(pattern: #"\[\^[^\[\]\s]+\]"#)
    private static let autolinkBeforePunctuation = try! NSRegularExpression(pattern: #"\#(autolink)(?=[.,;:!?)])"#)

    /// `<https://…>`, `<mailto:…>` and `<name@host>` anywhere else.
    private static let bareAutolink = try! NSRegularExpression(pattern: autolink)

    private static func compiled(_ rules: [(String, String, NSRegularExpression.Options)]) -> [(NSRegularExpression, String)] {
        rules.map { (try! NSRegularExpression(pattern: $0.0, options: $0.2), $0.1) }
    }

    static func plain(_ text: String) -> String {
        // Code is spoken as written: set it aside while the rules run. A text that
        // already holds the marker characters is cleaned without that protection.
        guard !text.contains(codeOpen), !text.contains(codeClose) else { return clean(text) }
        var spans: [String] = []
        let ns = text as NSString
        var held = ""
        var cursor = 0
        for match in codeSpan.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            held += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            held += "\(codeOpen)\(spans.count)\(codeClose)"
            spans.append(ns.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        held += ns.substring(from: cursor)
        var out = clean(held)
        for (index, span) in spans.enumerated().reversed() { out = out.replacingOccurrences(of: "\(codeOpen)\(index)\(codeClose)", with: span) }
        return out
    }

    private static func clean(_ text: String) -> String {
        func apply(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
            rules.reduce(text) { current, rule in
                rule.0.stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current), withTemplate: rule.1)
            }
        }
        let defined = apply(definitionRules, to: text)
        let linked = apply(inlineRules, to: removing(footnoteMark, from: defined))
        let trimmed = removing(autolinkBeforePunctuation, from: linked)
        let unlinked = bareAutolink.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: "")
        return stripHTML(unlinked)
    }

    private static func stripHTML(_ text: String) -> String {
        var out = text
        for (regex, template) in [(htmlComment, ""), (htmlBreak, "\n"), (htmlTag, "")] {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// `text` without each match of `regex` and the spaces and tabs in front of it.
    /// The spaces are found by looking back from the match, so a run of them is
    /// read once.
    private static func removing(_ regex: NSRegularExpression, from text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var start = match.range.location
            while start > cursor, ns.character(at: start - 1) == 0x20 || ns.character(at: start - 1) == 0x09 { start -= 1 }
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            cursor = match.range.location + match.range.length
        }
        return out + ns.substring(from: cursor)
    }
}
