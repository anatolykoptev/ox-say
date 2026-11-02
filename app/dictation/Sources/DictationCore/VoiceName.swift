import Foundation

/// The id a voice gets on disk from the label a person typed. The daemon's
/// voice names are file-name-safe ASCII (`internal/voices/store.go`
/// voiceNameRe); the label is free text, so the app derives the slug here.
public enum VoiceName {
    /// voices/store.go voiceNameRe: what the daemon accepts as a voice name.
    public static let idPattern = "^[a-z0-9][a-z0-9_-]{0,31}$"
    /// The longest id the daemon accepts (the pattern's 1 + 31).
    public static let maxIDLength = 32

    /// ГОСТ-style Cyrillic transliteration; every other non-ASCII falls into a
    /// separator run. Lowercase labels map through it unchanged.
    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    /// The slug for `label`: transliterated, lowercased, every run outside
    /// [a-z0-9] collapsed to one "-", dashes trimmed, cut to the daemon's
    /// length. A label that leaves nothing becomes "voice". When the slug is
    /// in `taken`, "-2", "-3", … is appended — the stem cut to leave room, so
    /// the whole id never outgrows the limit.
    public static func id(from label: String, taken: Set<String>) -> String {
        var mapped = ""
        for c in label.lowercased() {
            if let sub = cyrillic[c] {
                mapped += sub
            } else {
                mapped.append(isASCIIAlphanumeric(c) ? c : "-")
            }
        }
        var stem = mapped
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if stem.isEmpty { stem = "voice" }
        stem = String(stem.prefix(maxIDLength))
        var candidate = stem
        var suffixNumber = 1
        while taken.contains(candidate) {
            suffixNumber += 1
            let suffix = "-\(suffixNumber)"
            candidate = String(stem.prefix(maxIDLength - suffix.count)) + suffix
        }
        return candidate
    }

    /// The label the daemon would store for a name the app offers, or nil when
    /// it would refuse it — the app never proposes what the daemon rejects.
    /// Mirrors normalizeLabel (internal/daemon/voicemeta.go): surrounding
    /// whitespace trims away and does not count, the rest is at most 60 runes
    /// (unicode scalars — the daemon's own count), and no control, line or
    /// paragraph separator, or bidi (U+202A-202E, U+2066-2069) may sit inside.
    /// A blank name is not offered either; clearing a label is a PATCH of "".
    public static func validLabel(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.unicodeScalars.count <= 60 else { return nil }
        for scalar in label.unicodeScalars where
            CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 0x2028 || scalar.value == 0x2029
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) {
            return nil
        }
        return label
    }
}
