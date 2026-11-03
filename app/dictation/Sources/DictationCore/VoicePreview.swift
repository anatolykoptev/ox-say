import Foundation

/// What a person may call a voice. The daemon holds the label verbatim, so the app is the one place that refuses a
/// label the daemon would reject (or accept as an empty name): trimmed, not empty, at most 60 characters (the
/// daemon's `maxVoiceLabelChars`, counted as Unicode scalars — Go's runes), no control characters, no line or
/// paragraph separators and no text-direction controls.
public enum VoiceLabel {
    public static let maxChars = 60

    public static func clean(_ raw: String) -> String? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.unicodeScalars.count <= maxChars else { return nil }
        guard !label.unicodeScalars.contains(where: Self.refused) else { return nil }
        return label
    }

    /// The daemon's `normalizeLabel` refuses a control character (unicode.IsControl: the Cc set), a line or
    /// paragraph separator (U+2028/U+2029) and a bidi embedding, override or isolate (`meeting.HasBidiControl`:
    /// it reorders the text around it). Apple's `controlCharacters` is wider — it also holds the format
    /// characters (Cf, a ZWJ included), which the daemon does not refuse — so it is not the check.
    private static func refused(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2028, 0x2029, 0x202A ... 0x202E, 0x2066 ... 0x2069: return true
        default: return scalar.properties.generalCategory == .control
        }
    }
}

/// A deleted voice cannot stay a read-aloud pick: the pick would name a voice the daemon no longer has.
public enum VoicePicksCleanup {
    public static func afterDelete(id: String, russian: String?, english: String?) -> (russian: String?, english: String?) {
        (russian == id ? nil : russian, english == id ? nil : english)
    }
}

/// The sentence a voice is previewed with: one fixed short sentence per language, so two voices can be compared.
public enum VoicePreview {
    public static func sentence(for entry: VoiceEntry, locale: String) -> String {
        locale.hasPrefix("ru") ? "Это пример выбранного голоса." : "This is a preview of the selected voice."
    }

    /// The speak request's `language`, so the daemon does not infer it from the sentence.
    public static func language(locale: String) -> String { locale.hasPrefix("ru") ? "russian" : "english" }
}

/// The two read-aloud voice picks (`nil` is the engine's default; `MenuSections.randomVoice` is "random each time").
public struct ReadAloudPicks: Equatable {
    public var russian: String?
    public var english: String?
    public init(russian: String?, english: String?) {
        self.russian = russian
        self.english = english
    }
}

/// The daemon calls the library needs, injected so the behaviour runs without one.
public struct VoiceLibraryOps {
    public var list: () async throws -> [VoiceEntry]
    public var setLabel: (_ id: String, _ label: String) async throws -> Void
    public var delete: (_ id: String) async throws -> Void
    /// The sample's audio for (sentence, voice id, language).
    public var speak: (_ text: String, _ voice: String, _ language: String) async throws -> Data

    public init(list: @escaping () async throws -> [VoiceEntry],
                setLabel: @escaping (String, String) async throws -> Void,
                delete: @escaping (String) async throws -> Void,
                speak: @escaping (String, String, String) async throws -> Data) {
        self.list = list
        self.setLabel = setLabel
        self.delete = delete
        self.speak = speak
    }
}

public enum VoicePreviewOutcome: Equatable {
    /// Play this audio now.
    case play(Data)
    /// A stop, another preview or a delete came first: play nothing, say nothing.
    case dropped
    case failed(String)
}

/// The Voices page's behaviour, apart from drawing: the list and how its last read went, the read-aloud picks, rename,
/// delete and preview. On the main actor, like the window's glue (VoiceSource): `entries`, `load`, `playingID` and
/// the epochs are touched from one place only, so an answer landing off the wire can never tear them. The daemon
/// calls (`VoiceLibraryOps`) stay async and still leave the actor.
///
/// Invariants (each pinned by a test):
/// - a failed read keeps the last good list and says so; with none it is "unreachable", never "empty";
/// - an answer to a list read that began before a change (a delete, a rename, a newer read) is dropped;
/// - a delete that the daemon accepted (or reports as already gone) removes the voice from both read-aloud picks in the
///   same step; one it refused leaves the picks and the list alone;
/// - a rename with an empty or invalid label never reaches the daemon;
/// - one preview at a time; a stop makes the answer of a running one a no-op.
@MainActor
public final class VoiceLibrarySession {
    public private(set) var entries: [VoiceEntry] = []
    public private(set) var load: VoicesLoad = .loading
    /// The voice whose sample is being made or played.
    public private(set) var playingID: String?

    private let ops: VoiceLibraryOps
    private let readPicks: () -> ReadAloudPicks
    private let writePicks: (ReadAloudPicks) -> Void
    private let text: (L10nKey) -> String
    /// Counts every change of what a list read may still show: a read applies only if no change came after it began.
    private var epoch = 0
    private var previewEpoch = 0
    /// Set by the first list read that lands: only then do `entries` say what the daemon holds.
    private var everLoaded = false

    public init(ops: VoiceLibraryOps, readPicks: @escaping () -> ReadAloudPicks,
                writePicks: @escaping (ReadAloudPicks) -> Void, text: @escaping (L10nKey) -> String = { $0.text }) {
        self.ops = ops
        self.readPicks = readPicks
        self.writePicks = writePicks
        self.text = text
    }

    /// The read-aloud picks as stored now.
    public var picks: ReadAloudPicks { readPicks() }

    public var pageState: VoicesPageState { VoicesPageState.of(load: load, hasVoices: !entries.isEmpty) }

    /// The ids the read-aloud pickers and the menu may offer: `entries`' once the library was read at all, nil
    /// before. A failed refresh then keeps offering the list still held (a deleted voice stays out of it), and a
    /// daemon never reached offers nothing rather than a list nobody read.
    public var offeredIDs: [String]? { everLoaded ? entries.map(\.id) : nil }

    /// Reads the library again.
    public func reload() async {
        epoch += 1
        let mine = epoch
        do {
            let list = try await ops.list()
            guard mine == epoch else { return }
            entries = list
            load = .loaded
            everLoaded = true
        } catch {
            guard mine == epoch else { return }
            load = .failed(sentence(error))
        }
    }

    /// Renames to `label` (the id on disk stays). Returns the sentence to show when it did not go through.
    public func rename(id: String, label: String) async -> String? {
        guard let clean = VoiceLabel.clean(label) else { return text(.voicesRenameInvalid) }
        if entries.first(where: { $0.id == id })?.label == clean { return nil }
        // The new label shows at once, and a read that began earlier is stale, even if the next read fails.
        epoch += 1
        entries = entries.map { $0.id == id ? VoiceEntry(id: $0.id, label: clean, kind: $0.kind, created: $0.created, engine: $0.engine) : $0 }
        do {
            try await ops.setLabel(id, clean)
        } catch {
            // The PATCH may have landed despite the lost answer: one re-read shows what the daemon stored.
            await reload()
            return sentence(error)
        }
        await reload()
        return nil
    }

    /// Deletes the voice. Only a delete the daemon accepted touches the picks; a refusal restores the list and
    /// returns its sentence. A voice the daemon no longer has (404) is gone all the same: the picks are cleaned.
    public func delete(id: String) async -> String? {
        // Gone from the list at once, and a read that began earlier is stale, even if the next read fails.
        epoch += 1
        entries.removeAll { $0.id == id }
        if playingID == id { stopPreview() }
        do {
            try await ops.delete(id)
        } catch StudioError.refused(let status, _) where status == 404 {
            // Already gone: the cleanup stands.
        } catch {
            // Refused: put back what the daemon still holds.
            await reload()
            return sentence(error)
        }
        let before = readPicks()
        let cleaned = VoicePicksCleanup.afterDelete(id: id, russian: before.russian, english: before.english)
        let after = ReadAloudPicks(russian: cleaned.russian, english: cleaned.english)
        if after != before { writePicks(after) }
        await reload()
        return nil
    }

    /// Makes the voice's sample. `.play` carries the audio; `playingID` stays set until `previewEnded` or `stopPreview`.
    public func preview(id: String, locale: String) async -> VoicePreviewOutcome {
        previewEpoch += 1
        let mine = previewEpoch
        playingID = id
        let entry = entries.first { $0.id == id } ?? VoiceEntry(id: id, label: id, kind: .other)
        do {
            let audio = try await ops.speak(VoicePreview.sentence(for: entry, locale: locale), id,
                                            VoicePreview.language(locale: locale))
            guard mine == previewEpoch else { return .dropped }
            return .play(audio)
        } catch {
            guard mine == previewEpoch else { return .dropped }
            playingID = nil
            return .failed(SpeechError.plain(error, text: text))
        }
    }

    /// The sample ended on its own.
    public func previewEnded() { playingID = nil }

    /// A stop, or a close: whatever is being made is dropped when it arrives.
    public func stopPreview() {
        previewEpoch += 1
        playingID = nil
    }

    private func sentence(_ error: Error) -> String {
        (error as? StudioError)?.message(text: text) ?? text(.noticeErrorFallback)
    }
}
