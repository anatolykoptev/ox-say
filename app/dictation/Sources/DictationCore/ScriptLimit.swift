import Foundation

/// How long a script may be and how long it will take to read, as the review
/// sheet says it. The daemon counts the script in runes (produce_ops.go
/// `utf8.RuneCountInString`), that is Unicode scalars: not Swift Characters (a
/// letter with a combining mark is one Character and two runes) and not UTF-16
/// units (an emoji is two units and one rune). Every number here is a scalar count
/// of the exact string that is sent.
public enum ScriptLimit {
    /// The daemon's cap on a script (produce.go maxProduceChars).
    public static let maxCharacters = ProduceRequest.scriptLimit
    /// The daemon's own estimate of narration speed (produce.go estCharsPerSec,
    /// 13.9 characters a second, which makes 40000 characters about 48 minutes).
    public static let charsPerMinute = 13.9 * 60

    private static let sentenceEnds = Set(".!?…")

    /// What is sent: the editor's text without the white space around it.
    public static func script(from editorText: String) -> String {
        editorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The daemon's length of a script.
    public static func count(_ script: String) -> Int {
        script.unicodeScalars.count
    }

    /// Characters past the limit; 0 when the script fits.
    public static func overBy(_ script: String) -> Int {
        max(0, count(script) - maxCharacters)
    }

    /// Whole minutes of narration, at least 1 for any text.
    public static func minutes(characters: Int) -> Int {
        max(1, Int((Double(characters) / charsPerMinute).rounded()))
    }

    /// The live line under the text: its size, or why it cannot be started.
    public static func statusLine(editorText: String, text localized: (L10nKey) -> String = { $0.text }) -> String {
        let text = script(from: editorText)
        let length = count(text)
        if length == 0 { return localized(.scriptNone) }
        let over = overBy(text)
        if over > 0 {
            return String(format: localized(.scriptOver), String(length), String(over), String(maxCharacters),
                          String(minutes(characters: maxCharacters)))
        }
        let m = minutes(characters: length)
        return m == 1 ? String(format: localized(.scriptOneMinute), String(length))
                      : String(format: localized(.scriptMinutes), String(length), String(m))
    }

    /// The text can be started: it is not empty and not over the limit.
    public static func canStart(editorText: String) -> Bool {
        let length = count(script(from: editorText))
        return length > 0 && length <= maxCharacters
    }

    /// The longest start of the script that fits: it ends where a paragraph ends.
    /// A first paragraph that is itself too long is cut after its last sentence
    /// that fits, else at the last space, else at the limit.
    public static func keepFirstPart(_ text: String, limit: Int = maxCharacters) -> String {
        let all = Array(script(from: text).unicodeScalars)
        guard all.count > limit else { return String(String.UnicodeScalarView(all)) }
        let cut = lastParagraphBreak(all, within: limit) ?? lastSentenceEnd(all, within: limit) ?? lastSpace(all, within: limit) ?? limit
        let part = String(String.UnicodeScalarView(all[0..<cut]))
        return part.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The index of the blank line that follows the last paragraph that fits.
    private static func lastParagraphBreak(_ s: [Unicode.Scalar], within limit: Int) -> Int? {
        (1...limit).reversed().first { $0 + 1 < s.count && s[$0] == "\n" && s[$0 + 1] == "\n" }
    }

    private static func lastSentenceEnd(_ s: [Unicode.Scalar], within limit: Int) -> Int? {
        (1...limit).reversed().first { $0 < s.count && sentenceEnds.contains(Character(s[$0 - 1])) && s[$0].properties.isWhitespace }
    }

    private static func lastSpace(_ s: [Unicode.Scalar], within limit: Int) -> Int? {
        (1...limit).reversed().first { s[$0].properties.isWhitespace }
    }
}
