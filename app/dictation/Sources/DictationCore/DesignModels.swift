import Foundation

/// Voice design: the daemon renders candidate takes from a written description
/// (`POST /v1/audio/voices/design`) and keeps one under a name
/// (`POST /v1/audio/voices/design/save`).

/// One rendered candidate. `path` is a WAV the daemon wrote on this Mac.
public struct DesignTake: Equatable {
    public var path: String
    public var durationSeconds: Double
    /// A name the daemon proposes for the voice ("warm-female-narrator-1").
    public var suggestedName: String
    public var warning: String?

    public init(path: String, durationSeconds: Double, suggestedName: String, warning: String? = nil) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.suggestedName = suggestedName
        self.warning = warning
    }

    /// The takes of a design answer; nil when the answer has none.
    public static func decodeAll(_ data: Data) -> [DesignTake]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["takes"] as? [[String: Any]] else { return nil }
        let takes = list.compactMap { item -> DesignTake? in
            guard let path = item["path"] as? String, !path.isEmpty else { return nil }
            return DesignTake(path: path, durationSeconds: item["duration_s"] as? Double ?? 0,
                              suggestedName: item["suggested_name"] as? String ?? "",
                              warning: (item["warning"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return takes.isEmpty ? nil : takes
    }
}

/// A voice kept from a take.
public struct SavedVoice: Equatable {
    public var name: String
    public var notice: String?
    /// The machine-readable kind of `notice` — "shortened" or "text_replaced";
    /// nil when there is no notice or the daemon predates the field (#439).
    public var noticeCode: String?

    static func decode(_ data: Data) -> SavedVoice? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        return SavedVoice(name: name,
                          notice: (obj["notice"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          noticeCode: (obj["notice_code"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The answer to a save: kept, or "a voice with this name exists" (HTTP 409),
/// which the app turns into a question rather than an error.
public enum SaveOutcome: Equatable {
    case saved(SavedVoice)
    case nameTaken

    /// The decision on the daemon's answer: 409 asks to replace; any other
    /// non-2xx is the daemon's own message.
    static func interpret(status: Int, data: Data) throws -> SaveOutcome {
        if status == 409 { return .nameTaken }
        guard (200..<300).contains(status) else { throw StudioClient.refusal(status: status, body: data) }
        guard let voice = SavedVoice.decode(data) else { throw StudioError.badResponse }
        return .saved(voice)
    }
}

public enum DesignRequest {
    /// Candidate takes per design; the daemon's own default.
    public static let takeCount = 3

    public static func body(description: String, text: String) -> Data {
        let body: [String: Any] = ["description": description.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "text": text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "takes": takeCount]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    public static func saveBody(name: String, take: String, replace: Bool) -> Data {
        var body: [String: Any] = ["name": name, "take": take]
        if replace { body["replace"] = true }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

/// What the describe-a-voice form accepts, from the daemon's own limits.
public enum DesignForm {
    /// vscript.MaxStyleChars and design.go maxDesignText.
    public static let descriptionLimit = 300
    /// The sample sentence is capped by spoken duration, like the daemon (design.go designTextUnits): 1/60 s per unit,
    /// 6 per character at the Russian pace, so 200 Latin or Cyrillic characters fill the 20 s window (1200 units).
    /// Han costs 15 (4 chars/s), kana, Hangul and Thai 10 (6 chars/s): conservative rates, not measured.
    public static let sentenceLimit = 200
    static let unitsPerCharacter = 6
    static let unitsPerHan = 15
    static let unitsPerSyllable = 10
    static let sentenceUnitLimit = sentenceLimit * unitsPerCharacter

    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{sc=Han}"#)
    private static let syllablePattern = try! NSRegularExpression(pattern: #"[\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}\p{sc=Thai}]"#)

    /// The slowest plausible spoken length of `text`, in 1/60 s; one unit rule with the daemon, counted per Unicode scalar.
    public static func sentenceUnits(_ text: String) -> Int {
        let whole = NSRange(text.startIndex..., in: text)
        let han = hanPattern.numberOfMatches(in: text, range: whole)
        let syllables = syllablePattern.numberOfMatches(in: text, range: whole)
        let others = text.unicodeScalars.count - han - syllables
        return others * unitsPerCharacter + han * unitsPerHan + syllables * unitsPerSyllable
    }

    /// How many characters of `text`'s own script fit: 200 for Russian, 80 for Chinese (the daemon's refusal figure).
    public static func sentenceCap(for text: String) -> Int {
        let units = sentenceUnits(text)
        guard units > 0 else { return sentenceLimit }
        return sentenceUnitLimit * text.unicodeScalars.count / units
    }
    public static func descriptionPlaceholder(text: (L10nKey) -> String = { $0.text }) -> String {
        text(.designFormDescriptionPlaceholder)
    }
    public static let defaultSentence =
        "Здравствуйте! Рада познакомиться, сегодня мы вместе расскажем вам что-то интересное."

    /// The first thing wrong with the description or the sample sentence, in plain words; nil when they can be sent.
    /// The label is the flow's to judge (VoiceDesignFlow.submit): it is free text, the id on disk is derived from it.
    public static func problem(description: String, sentence: String,
                               text: (L10nKey) -> String = { $0.text }) -> String? {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { return text(.designProblemDescribe) }
        if description.count > descriptionLimit { return String(format: text(.designProblemDescriptionLong), String(descriptionLimit)) }
        if sentence.isEmpty { return text(.designProblemSentenceEmpty) }
        if sentenceUnits(sentence) > sentenceUnitLimit {
            return String(format: text(.designProblemSentenceLong), String(sentenceCap(for: sentence)))
        }
        return nil
    }

    /// "Take 2 of 3".
    public static func takeTitle(index: Int, count: Int, text: (L10nKey) -> String = { $0.text }) -> String {
        String(format: text(.designTakeTitle), String(index + 1), String(count))
    }

    /// The daemon's warning about a take, in words for a listener. A warning the app does not know is the daemon's
    /// own English sentence, capitalized.
    public static func warningText(_ warning: String, text: (L10nKey) -> String = { $0.text }) -> String {
        if warning.contains("babble") { return text(.designTakeBabble) }
        return warning.prefix(1).uppercased() + warning.dropFirst()
    }

    /// The line under a kept voice: "Voice “x” saved", plus the sentence saying what the daemon did
    /// to the clip or its text — picked from `notice_code`, never from the English `notice` (#439).
    /// An unknown code (or none, from a daemon that predates it) gets a neutral sentence after the
    /// name, never "shortened"; no notice is the bare saved line, as before.
    public static func savedNotice(name: String, voice: SavedVoice, text: (L10nKey) -> String = { $0.text }) -> String {
        let saved = String(format: text(.designSaved), name)
        guard voice.notice?.isEmpty == false else { return saved }
        switch voice.noticeCode {
        case "shortened":
            return saved + ". " + text(.designShortened)
        case "text_replaced":
            return saved + ". " + text(.designTextReplaced)
        default:
            return saved + ". " + text(.designSavedAdjusted)
        }
    }
}
