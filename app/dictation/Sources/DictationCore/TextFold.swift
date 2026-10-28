import Foundation

/// The comparison the daemon's search makes (`internal/meeting/search.go` foldRune), so the window's find and its
/// emphasis of a snippet match exactly where the daemon matched: lower case, and a letter with a mark as its plain
/// letter (é as e, ё as е). й is deliberately not и: to a Russian reader it is a letter of its own, and "мои" must not
/// find "мой". Like the daemon's, the fold is per scalar and does no Unicode normalisation.
public enum TextFold {
    /// Lower-case letters with a mark (or a stroke) and the plain letter each stands for. The daemon's table.
    private static let accents: [Unicode.Scalar: Unicode.Scalar] = {
        let groups: [(Character, String)] = [
            ("a", "àáâãäåāăąǎǻǟǡȁȃȧ"), ("c", "çćĉċč"), ("d", "ďđ"), ("e", "èéêëēĕėęěȅȇȩ"), ("g", "ĝğġģǧ"), ("h", "ĥħ"),
            ("i", "ìíîïĩīĭįıǐȉȋ"), ("j", "ĵ"), ("k", "ķ"), ("l", "ĺļľŀł"), ("n", "ñńņňŉ"), ("o", "òóôõöøōŏőǒǿȍȏ"),
            ("r", "ŕŗřȑȓ"), ("s", "śŝşšș"), ("t", "ţťŧț"), ("u", "ùúûüũūŭůűųǔȕȗ"), ("w", "ŵ"), ("y", "ýÿŷ"), ("z", "źżž"),
            ("е", "ё"), ("і", "ї"),
            ("α", "ά"), ("ε", "έ"), ("η", "ή"), ("ι", "ίϊΐ"), ("ο", "ό"), ("υ", "ύϋΰ"), ("ω", "ώ"),
        ]
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (base, letters) in groups {
            for letter in letters.unicodeScalars { map[letter] = base.unicodeScalars.first! }
        }
        return map
    }()

    /// The scalar a search compares. The daemon's `ToLower(ToUpper(r))` round trip folds ς to σ and ſ to s; a case
    /// mapping that is not one scalar (ß to "SS") leaves the letter as it is, as Go's one-to-one mapping does.
    public static func scalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        if s.value < 0x80 {
            return (0x41...0x5A).contains(s.value) ? Unicode.Scalar(s.value + 0x20)! : s
        }
        var r = s
        if let up = single(s.properties.uppercaseMapping) { r = up }
        if r.value == 0x130 { r = "i" } // Go's simple lower case of İ; the full mapping is two scalars
        else if let low = single(r.properties.lowercaseMapping) { r = low }
        return accents[r] ?? r
    }

    private static func single(_ mapping: String) -> Unicode.Scalar? {
        let scalars = mapping.unicodeScalars
        return scalars.count == 1 ? scalars.first : nil
    }

    /// The text as the search compares it (for tests and for the needle).
    public static func folded(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars { out.append(scalar(s)) }
        return String(out)
    }

    /// Where `needle` occurs in `text` ignoring case and marks: Character offsets, left to right, not overlapping.
    /// An empty needle occurs nowhere.
    public static func ranges(of needle: String, in text: String) -> [Range<Int>] {
        let pattern = needle.unicodeScalars.map(scalar)
        guard !pattern.isEmpty else { return [] }
        var hay: [Unicode.Scalar] = []
        var charOf: [Int] = []
        for (offset, ch) in text.enumerated() {
            for s in ch.unicodeScalars {
                hay.append(scalar(s))
                charOf.append(offset)
            }
        }
        var out: [Range<Int>] = []
        var i = 0
        while i + pattern.count <= hay.count {
            if hay[i..<(i + pattern.count)].elementsEqual(pattern) {
                out.append(charOf[i]..<(charOf[i + pattern.count - 1] + 1))
                i += pattern.count
            } else {
                i += 1
            }
        }
        return out
    }
}
