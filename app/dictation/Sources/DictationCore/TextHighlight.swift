import Foundation

/// A mark on a run of text: a place the find or the search matched, and the one the user is on now. A custom attribute,
/// so the view decides how it looks and a bold word the text already had is never taken for a match.
public enum TextHighlight {
    public enum Kind: String, Codable, Hashable { case match, current }

    public enum Key: CodableAttributedStringKey {
        public typealias Value = Kind
        public static let name = "oxsay.highlight"
    }

    /// `text` as it is, with each range (Character offsets) marked; the range at `current` is the current one.
    public static func attributed(_ text: String, ranges: [Range<Int>], current: Int? = nil) -> AttributedString {
        var out = AttributedString(text)
        mark(&out, ranges: ranges, current: current)
        return out
    }

    static func mark(_ out: inout AttributedString, ranges: [Range<Int>], current: Int?) {
        let chars = out.characters
        for (i, r) in ranges.enumerated() {
            guard r.lowerBound >= 0, r.upperBound <= chars.count, r.lowerBound < r.upperBound else { continue }
            let lo = chars.index(chars.startIndex, offsetBy: r.lowerBound)
            let hi = chars.index(chars.startIndex, offsetBy: r.upperBound)
            out[lo..<hi].oxsayHighlight = (i == current) ? .current : .match
        }
    }
}

extension AttributeScopes {
    public struct OxSayAttributes: AttributeScope {
        public let oxsayHighlight: TextHighlight.Key
    }

    public var oxsay: OxSayAttributes.Type { OxSayAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.OxSayAttributes, T>) -> T {
        self[T.self]
    }
}

/// A search snippet: untrusted text with the matched words emphasised and no link.
public enum SearchSnippet {
    public static func attributed(_ snippet: String, query: String) -> AttributedString {
        var out = InlineMarkdown.attributed(snippet)
        TextHighlight.mark(&out, ranges: TextFold.ranges(of: query, in: String(out.characters)), current: nil)
        return out
    }
}
