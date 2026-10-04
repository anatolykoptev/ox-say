import Foundation

/// The app's per-language voice pick. The menu stores a Russian and an
/// English choice separately; the text's script decides which one a speak
/// request sends. This mirrors the daemon's script detection — any Cyrillic
/// marks Russian, otherwise Latin letters mark English — so a text the daemon
/// would route to a language gets that language's pick here.
public enum VoicePick {
    /// The daemon's langHint: the first Cyrillic scalar wins outright, Latin
    /// letters mark English, anything else returns nil so the daemon's
    /// configured chain applies.
    public static func languageHint(of text: String) -> String? {
        var latin = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // The Cyrillic ranges Go's unicode.Is(unicode.Cyrillic) covers;
            // the first hit returns Russian outright, same as the daemon.
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x1D2B, 0x1D78, 0x2DE0...0x2DFF, 0xA640...0xA69F,
                 0xFE2E...0xFE2F:
                return "ru"
            // Go's Latin script table; the Phonetic Extensions block is
            // split because Greek letters sit inside it (1D26-1D2A, 1D5D-1D61,
            // 1D66-1D6A, 1DBF).
            case 0x0041...0x005A, 0x0061...0x007A, 0x00AA, 0x00BA, 0x00C0...0x00D6, 0x00D8...0x00F6,
                 0x00F8...0x02B8, 0x02E0...0x02E4, 0x1D00...0x1D25, 0x1D2C...0x1D5C, 0x1D62...0x1D65,
                 0x1D6B...0x1D77, 0x1D79...0x1DBE, 0x1E00...0x1EFF, 0x2071, 0x207F, 0x2090...0x209C,
                 0x212A...0x212B, 0x2132, 0x214E, 0x2160...0x2188, 0x2C60...0x2C7F, 0xA720...0xA7FF,
                 0xAB30...0xAB6F, 0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
                 0x10780...0x107BA, 0x1DF00...0x1DF1E:
                latin = true
            default:
                break
            }
        }
        return latin ? "en" : nil
    }

    /// The voice to send for `text`: the stored pick for the detected
    /// language ("default" means the engine's random voice), or nil when the
    /// script is neither Russian nor English — the daemon's configured
    /// default then applies.
    public static func voice(for text: String, russian: String?, english: String?) -> String? {
        switch languageHint(of: text) {
        case "ru": return russian
        case "en": return english
        default: return nil
        }
    }
}
