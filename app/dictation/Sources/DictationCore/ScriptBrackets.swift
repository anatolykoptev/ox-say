import Foundation

/// Square brackets in a script, written against the daemon's parser
/// (internal/vscript/markup.go). The parser reads every `[...]` pair that has no
/// bracket or line break inside as a directive: `[pause 0.6s]` anywhere, or
/// `[style: ...]` opening a paragraph. Any other pair rejects the whole script
/// ("unknown directive"), and so does a pause outside 0.05-10 s, a pause before the
/// first spoken text and a style anywhere else. So no `[...]` reaches the daemon
/// unless it is a directive the parser accepts, and only a script the owner wrote
/// (plain text, Markdown) may keep those.
enum ScriptBrackets {
    /// markup.go:53 directiveRe, character for character.
    static let directivePattern = #"\[([^\[\]\n]*)\]"#
    /// markup.go:54 pauseRe (the daemon lowercases and trims the text first).
    static let pausePattern = #"^pause(?:[ \t\f\r]+([0-9]+(?:[.,][0-9]+)?)[ \t\f\r]*(ms|s)?)?$"#
    /// markup.go:55 styleRe.
    static let stylePattern = #"^style[ \t\f\r]*:[ \t\f\r]*(.*)$"#
    /// A footnote marker: `[1]`, `[12]`, `[1, 2]`, `[3-5]`, with the spaces before it.
    static let footnotePattern = #"[ \t]*\[\s*[0-9]+(?:\s*[,–-]\s*[0-9]+)*\s*\]"#

    static let minPauseSeconds = 0.05
    static let maxPauseSeconds = 10.0
    static let millisecondsPerSecond = 1000.0
    /// style.go MaxStyleChars.
    static let maxStyleCharacters = 300
    /// style.go styleDrops: parentheses and their lookalikes.
    static let styleDrops = "()（）﹙﹚⁽⁾₍₎"
    /// Text that closes a sentence or opens a quote: no space is put before/after it.
    private static let noSpaceBefore = Set(".,;:!?…)»”\"'")
    private static let noSpaceAfter = Set("(«“\"'")

    private static let directive = try! NSRegularExpression(pattern: directivePattern)
    private static let pause = try! NSRegularExpression(pattern: pausePattern)
    private static let style = try! NSRegularExpression(pattern: stylePattern, options: .caseInsensitive)
    private static let footnote = try! NSRegularExpression(pattern: footnotePattern)

    /// Footnote markers removed; every other bracket pair loses its brackets and
    /// keeps its words. With `keepDirectives`, the pairs the parser accepts stay.
    /// `text` is paragraphs separated by one blank line, lines already trimmed.
    static func neutralise(_ text: String, keepDirectives: Bool) -> String {
        let withoutNotes = footnote.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        var spoken = false
        return withoutNotes.components(separatedBy: "\n\n").map {
            rewrite(paragraph: $0, keepDirectives: keepDirectives, spoken: &spoken)
        }.joined(separator: "\n\n")
    }

    private static func rewrite(paragraph: String, keepDirectives: Bool, spoken: inout Bool) -> String {
        let ns = paragraph as NSString
        var out = ""
        var cursor = 0
        func appendText(_ piece: String) {
            out += piece
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spoken = true }
        }
        for match in directive.matches(in: paragraph, range: NSRange(location: 0, length: ns.length)) {
            appendText(stripStray(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            cursor = match.range.location + match.range.length
            let inner = ns.substring(with: match.range(at: 1))
            let rest = ns.substring(from: cursor)
            let atStart = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if keepDirectives, spoken, isPause(inner) {
                out += ns.substring(with: match.range)
            } else if keepDirectives, atStart, isStyle(inner), hasText(stripStray(rest)) {
                out += ns.substring(with: match.range)
            } else {
                appendText(padded(inner.trimmingCharacters(in: .whitespacesAndNewlines), after: out, before: rest))
            }
        }
        appendText(stripStray(ns.substring(from: cursor)))
        return out
    }

    private static func hasText(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func stripStray(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }

    /// The words of a dropped pair, with a space on a side that would otherwise
    /// glue them to a neighbouring word.
    private static func padded(_ words: String, after previous: String, before next: String) -> String {
        guard !words.isEmpty else { return "" }
        var result = words
        if let last = previous.last, !last.isWhitespace, !noSpaceAfter.contains(last) { result = " " + result }
        if let first = next.first, !first.isWhitespace, !noSpaceBefore.contains(first), first != "[" { result += " " }
        return result
    }

    // MARK: what the parser accepts

    /// markup.go splitPauses + pauseSeconds.
    static func isPause(_ inner: String) -> Bool {
        let lower = inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let m = pause.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else { return false }
        let ns = lower as NSString
        guard m.range(at: 1).location != NSNotFound else { return true }
        let number = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")
        guard var seconds = Double(number) else { return false }
        if m.range(at: 2).location != NSNotFound, ns.substring(with: m.range(at: 2)) == "ms" { seconds /= millisecondsPerSecond }
        return seconds >= minPauseSeconds && seconds <= maxPauseSeconds
    }

    /// markup.go leadingStyle: a description that is not empty once cleaned, within the cap.
    static func isStyle(_ inner: String) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = style.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return false }
        let cleaned = cleanStyle((trimmed as NSString).substring(with: m.range(at: 1)))
        return !cleaned.isEmpty && cleaned.unicodeScalars.count <= maxStyleCharacters
    }

    /// style.go CleanStyle.
    static func cleanStyle(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if styleDrops.unicodeScalars.contains(u) || u.properties.generalCategory == .format { continue }
            if u.properties.generalCategory == .control { out.append(" ") } else { out.append(u) }
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
