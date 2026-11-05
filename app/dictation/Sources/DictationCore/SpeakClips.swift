import Foundation

/// One finished fast-voice take, kept for the session (window-plan decision D3: clips are never written to disk
/// by the app; «Сохранить…» is the person's own act).
public struct SpeakClip: Identifiable {
    public var id: String
    public var title: String
    public var text: String
    /// The voice id the take was made with; nil is the engine's default voice.
    public var voice: String?
    public var seconds: Double
    public var wav: Data
    public var created: Date

    public init(id: String, title: String, text: String, voice: String?, seconds: Double, wav: Data, created: Date) {
        self.id = id
        self.title = title
        self.text = text
        self.voice = voice
        self.seconds = seconds
        self.wav = wav
        self.created = created
    }
}

/// Equality ignores the audio bytes: the window's values are compared on every change and the clips hold up to
/// 200 MB. The id is unique per take, so two clips with one id are the same clip.
extension SpeakClip: Equatable {
    public static func == (a: SpeakClip, b: SpeakClip) -> Bool {
        a.id == b.id && a.title == b.title && a.text == b.text && a.voice == b.voice && a.seconds == b.seconds
            && a.created == b.created && a.wav.count == b.wav.count
    }
}

public enum SpeakClips {
    public static let maxCount = 20
    public static let maxBytes = 200_000_000

    /// `clip` first, then the older ones that still fit: at most `maxCount` clips and `maxBytes` of audio. The new
    /// clip is always kept, even when it alone is over the budget; the first older clip that does not fit ends the list.
    public static func append(_ clip: SpeakClip, to list: [SpeakClip]) -> [SpeakClip] {
        var kept = [clip]
        var bytes = clip.wav.count
        for older in list {
            guard kept.count < maxCount, bytes + older.wav.count <= maxBytes else { break }
            kept.append(older)
            bytes += older.wav.count
        }
        return kept
    }

    /// The first words of the text, for the list row.
    public static func title(of text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let head = words.prefix(6).joined(separator: " ")
        guard words.count > 6 else { return head }
        // "voice." + "…" reads as a typo: the ellipsis replaces the stop.
        return head.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")) + "…"
    }

    /// A file name for «Сохранить…»: path separators and colons are replaced, a leading dot is dropped.
    public static func fileName(forTitle title: String) -> String {
        var name = title.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "voiceover" }
        return String(name.prefix(60)) + ".wav"
    }

    /// m:ss
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The voice a restored clip may ask for.
public enum SpeakVoice {
    /// `voice` when the library still has it, else nil (the standard voice): a deleted voice is never requested.
    public static func existing(_ voice: String?, in voices: [String]) -> String? {
        guard let voice, voices.contains(voice) else { return nil }
        return voice
    }
}
