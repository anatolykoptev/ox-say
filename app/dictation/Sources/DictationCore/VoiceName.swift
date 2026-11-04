import Foundation

/// The id a voice gets on disk from the label a person typed. The daemon's
/// voice names are file-name-safe ASCII (`internal/voices/store.go`
/// voiceNameRe); the label is free text, so the app derives the slug here.
public enum VoiceName {
    /// voices/store.go voiceNameRe: what the daemon accepts as a voice name.
    public static let idPattern = "^[a-z0-9][a-z0-9_-]{0,31}$"
    /// The longest id the daemon accepts (the pattern's 1 + 31).
    public static let maxIDLength = 32

    /// ГОСТ-style Cyrillic transliteration, with the Ukrainian, Belarusian,
    /// Serbian/Macedonian and Kazakh letters; every other non-ASCII scalar falls
    /// into a separator run. Keyed by unicode scalar, on the lowercased label.
    private static let cyrillic: [Unicode.Scalar: String] = Dictionary(uniqueKeysWithValues: cyrillicTable.map {
        (Unicode.Scalar($0.key.unicodeScalars.first!), $0.value)
    })
    private static let cyrillicTable: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // Ukrainian, Belarusian
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
        // Serbian, Macedonian
        "ј": "j", "љ": "lj", "њ": "nj", "ћ": "c", "џ": "dzh", "ђ": "dj", "ѓ": "gj", "ќ": "kj", "ѕ": "dz",
        // Kazakh and other Turkic Cyrillic
        "ә": "a", "ғ": "gh", "қ": "q", "ң": "ng", "ө": "o", "ү": "u", "ұ": "u", "һ": "h",
    ]

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value)
    }

    /// Whether a cleaned label names a voice that exists: by the id it slugs to, or by the label itself, case-insensitively.
    /// `taken` holds the ids and the lower-cased labels of the library. The one rule every add sheet follows.
    public static func isTaken(_ clean: String, in taken: Set<String>) -> Bool {
        taken.contains(id(from: clean, taken: [])) || taken.contains(clean.lowercased())
    }

    /// The slug for `label`: transliterated, lowercased, every run outside
    /// [a-z0-9] collapsed to one "-", dashes trimmed, cut to the daemon's
    /// length. A label that leaves nothing becomes "voice". When the slug is
    /// in `taken`, "-2", "-3", … is appended — the stem cut to leave room, so
    /// the whole id never outgrows the limit.
    public static func id(from label: String, taken: Set<String>) -> String {
        var mapped = ""
        // Scalars, not Characters: an ASCII letter followed by combining scalars is one
        // Character, and judging it whole lets the marks into the id. NFC first, so a
        // decomposed "й" (и + breve) is the letter the table knows.
        for scalar in label.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            if let sub = cyrillic[scalar] {
                mapped += sub
            } else {
                mapped.unicodeScalars.append(isASCIIAlphanumeric(scalar) ? scalar : "-")
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
    /// Cc only, not the wider "control" set: a ZWJ, a variation selector or a
    /// keycap is stored, so a family emoji is offered. A blank name is not offered either; clearing a label is a PATCH of "".
    public static func validLabel(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.unicodeScalars.count <= 60 else { return nil }
        for scalar in label.unicodeScalars where isRefusedByTheDaemon(scalar) { return nil }
        return label
    }

    /// unicode.IsControl (Cc: U+0000-001F, U+007F-009F), U+2028, U+2029 and
    /// meeting.isBidiControl (U+202A-202E, U+2066-2069) — nothing else.
    private static func isRefusedByTheDaemon(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v <= 0x1F || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029
            || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }
}
