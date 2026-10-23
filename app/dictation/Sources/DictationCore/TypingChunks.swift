/// Splits dictated text into chunks a synthetic key event can carry:
/// CGEventKeyboardSetUnicodeString takes at most `maxUnits` UTF-16 units per
/// call. A chunk never ends inside a surrogate pair or a grapheme cluster,
/// so Russian text and emoji arrive whole.
public enum TypingChunks {
    /// The CGEventKeyboardSetUnicodeString limit, in UTF-16 units.
    public static let maxUnits = 20

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x85 }
    }

    /// `text` as chunks of at most `maxUnits` UTF-16 units each.
    ///
    /// A newline Character (`\n`, `\r`, and the single `\r\n` cluster) becomes
    /// one space: a typed "\n" is Return, which sends the message in a chat
    /// app. So does every Character made only of control scalars (C0 below
    /// 0x20, DEL 0x7F, U+0085): Tab would move focus, ESC and BS would act as
    /// keys, not text. Dictated text normally has none.
    ///
    /// A single grapheme cluster longer than the cap (a five-member family
    /// emoji is 24 units) cannot be sent whole. It is split at scalar
    /// boundaries — never inside a surrogate pair — and the events arrive in
    /// order, so the app composes the same cluster. The last piece of such a
    /// cluster stays open: the text that follows it joins that piece in the
    /// same chunk, up to the cap.
    public static func split(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = String.UnicodeScalarView()
        var currentUnits = 0
        func flush() {
            if !current.isEmpty { chunks.append(String(current)) }
            current = String.UnicodeScalarView()
            currentUnits = 0
        }
        for character in text {
            let piece = character.isNewline || isControl(character) ? " " : character
            let units = piece.utf16.count
            if currentUnits + units <= maxUnits {
                current.append(contentsOf: piece.unicodeScalars)
                currentUnits += units
            } else if units <= maxUnits {
                flush()
                current.append(contentsOf: piece.unicodeScalars)
                currentUnits = units
            } else {
                flush()
                for scalar in piece.unicodeScalars {
                    let width = scalar.utf16.count
                    if currentUnits + width > maxUnits { flush() }
                    current.append(scalar)
                    currentUnits += width
                }
            }
        }
        flush()
        return chunks
    }
}
