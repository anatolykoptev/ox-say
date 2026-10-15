import Foundation

/// What a Markdown file says aloud: the words, without the syntax that points
/// elsewhere. A link is read as its text and an image as its alt text; the
/// address is for the eye. Runs before the bracket rules, so `[text](url)` never
/// reaches them as a bracket pair, and the daemon's own `[pause 1s]` and
/// `[style: calm]` (a pair with no `(` or `[` right after it) pass through.
enum MarkdownText {
    /// A bracketed address: `(url)`, `(url "title")`, one level of nested parentheses in the url.
    private static let target = #"\((?:[^()\n]|\([^()\n]*\))*\)"#

    private static let autolink = #"<(?:(?:https?|ftp|mailto):[^<>\s]*|[^<>\s@]+@[^<>\s]+)>"#

    /// Applied in this order; each is `(pattern, template, options)`.
    private static let rules: [(NSRegularExpression, String)] = [
        // `[ref]: url "title"` definitions, whole lines.
        (#"^ {0,3}\[[^\[\]\n]+\]:[ \t]*\S.*\n?"#, "", [.anchorsMatchLines]),
        // `- [ ] item` and `- [x] item`: the box is not speech.
        (#"^([ \t]*[-*+][ \t]+)\[[ xX]\][ \t]+"#, "$1", [.anchorsMatchLines]),
        // `![alt](url)` and `![alt][ref]`: the alt text, or nothing.
        (#"!\[([^\[\]\n]*)\](?:\#(target)|\[[^\[\]\n]*\])"#, "$1", []),
        // `[text](url)`.
        (#"\[([^\[\]\n]*)\]\#(target)"#, "$1", []),
        // `[text][ref]` and `[text][]`, unless the text is a footnote number: `[1][2]`.
        (#"\[([^\[\]\n0-9][^\[\]\n]*)\]\[[^\[\]\n]*\]"#, "$1", []),
        // `<https://…>`, `<mailto:…>` and `<name@host>`; before a full stop or comma
        // the space in front goes too.
        (#"[ \t]*\#(autolink)(?=[.,;:!?)])"#, "", []),
        (#"\#(autolink)"#, "", []),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: $0.2), $0.1) }

    static func plain(_ text: String) -> String {
        rules.reduce(text) { current, rule in
            rule.0.stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current), withTemplate: rule.1)
        }
    }
}
