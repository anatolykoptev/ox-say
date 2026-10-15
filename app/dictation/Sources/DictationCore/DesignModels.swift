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

    static func decode(_ data: Data) -> SavedVoice? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        return SavedVoice(name: name, notice: (obj["notice"] as? String).flatMap { $0.isEmpty ? nil : $0 })
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

/// What the Create a Voice form accepts, from the daemon's own limits.
public enum DesignForm {
    /// vscript.MaxStyleChars and design.go maxDesignText.
    public static let descriptionLimit = 300
    public static let sentenceLimit = 200
    /// voices/store.go voiceNameRe.
    static let namePattern = "^[a-z0-9][a-z0-9_-]{0,31}$"

    public static let descriptionPlaceholder =
        "A warm female narrator in her thirties, native Russian speaker, lively and friendly"
    public static let defaultSentence =
        "Здравствуйте! Рада познакомиться, сегодня мы вместе расскажем вам что-то интересное."

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    /// The first thing wrong with the form, in plain words; nil when it can be sent.
    public static func problem(description: String, sentence: String, name: String) -> String? {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty { return "Describe the voice first." }
        if description.count > descriptionLimit { return "The description is too long: keep it under \(descriptionLimit) characters." }
        if sentence.isEmpty { return "Write a sample sentence for the voice to say." }
        if sentence.count > sentenceLimit { return "The sample sentence is too long: keep it under \(sentenceLimit) characters." }
        if !isValidName(name) {
            return "The name can use lowercase English letters, digits, - and _, up to 32 characters, and must start with a letter or digit."
        }
        return nil
    }

    /// "Take 2 of 3".
    public static func takeTitle(index: Int, count: Int) -> String { "Take \(index + 1) of \(count)" }

    /// The daemon's warning about a take, in words for a listener.
    public static func warningText(_ warning: String) -> String {
        if warning.contains("babble") {
            return "This take may contain stray sounds. Listen closely, or try the next take."
        }
        return warning.prefix(1).uppercased() + warning.dropFirst()
    }

    /// What the daemon's notice about a saved voice (it only says a long clip was cut) means to a listener.
    public static let shortenedNotice = "The recording was longer than a voice can keep, so it was shortened."
}
