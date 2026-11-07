import Foundation

/// The five moods a phrase can be given. The engine takes the mood as a style word in the project's language, so the
/// word sent stays Russian whatever language the window shows; the name on the chip is localized (`SpeakText.moodName`).
/// There is no strength control: the engine has none that works (plan constraint 3).
public enum Mood: String, CaseIterable {
    case calm, warm, energetic, excited, serious

    /// The style text sent to the daemon.
    public var styleWord: String {
        switch self {
        case .calm: return "спокойно"
        case .warm: return "тепло"
        case .energetic: return "энергично"
        case .excited: return "восторженно"
        case .serious: return "серьёзно"
        }
    }
}

/// One row of the phrase list on a finished project: what the person reads and which controls the row has.
public struct PhraseRowValue: Equatable, Identifiable {
    public var index: Int
    public var preview: String
    public var state: PhraseState
    /// The style text the daemon holds for the phrase (nil = as usual).
    public var style: String?
    /// The one of the five moods that style is, nil for none or for a style written some other way.
    public var mood: Mood?
    /// Zero-based position of the picked variant among the phrase's variants.
    public var variant: Int
    public var variants: Int
    /// The picked variant has a file to play.
    public var playable: Bool

    public var id: Int { index }
}

/// The decisions behind a phrase's mood, variants and text. Pure; `SpeakSource` carries them out against the daemon.
public enum PhraseEditing {
    /// The longest style text a phrase may carry.
    public static let maxStyleCharacters = 300

    /// The style text for a mood or a typed one; nil = as usual. A typed text is trimmed, folded to single spaces and
    /// capped; one with parentheses (which the engine reads as a style tag of its own) or brackets (directives, which the
    /// daemon refuses) is dropped instead of being sent.
    public static func style(for mood: Mood?, custom: String?) -> String? {
        if let mood { return mood.styleWord }
        guard let custom else { return nil }
        let folded = custom.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if folded.isEmpty { return nil }
        if folded.contains("(") || folded.contains(")") { return nil }
        if folded.contains("[") || folded.contains("]") { return nil }
        return String(folded.prefix(maxStyleCharacters))
    }

    /// The mood a stored style text is.
    public static func mood(of style: String?) -> Mood? {
        guard let style else { return nil }
        return Mood.allCases.first { $0.styleWord == style }
    }

    /// «Вариант 2 из 3» for the zero-based `index`.
    public static func variantLabel(index: Int, of count: Int, text: (L10nKey) -> String) -> String {
        String(format: text(.speakPhraseVariant), index + 1, count)
    }

    /// The variant after `current`, wrapping around; the first one when none is picked yet.
    public static func nextPick(current: String?, keys: [String]) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let current, let at = keys.firstIndex(of: current) else { return keys[0] }
        return keys[(at + 1) % keys.count]
    }

    /// The words of a finished or stopped project may be changed; a running one is being written by the daemon, which
    /// refuses a second operation until it ends.
    public static func canEditText(status: ProduceStatus) -> Bool {
        status.isTerminal
    }

    /// The batch entry for a mood. Choosing «как обычно» sends an empty style: the daemon leaves a nil one alone and clears
    /// only an empty one, so a nil here would keep the old mood while the chip said it was gone.
    public static func deliveryEntry(chunk: Int, mood: Mood?) -> DeliveryEntry {
        DeliveryEntry(n: chunk, style: mood?.styleWord ?? "")
    }

    /// Whether a project's phrases carry mood chips. The studio voice only; the controls matrix (`SpeakControls`) decides:
    /// in the simple mode a designed voice shows them (its mood effect is measured), a cloned or unknown voice does not;
    /// Advanced shows them for any voice. Projects of Озвучка are made with `clone_mode: "reference"`, so the recording's own
    /// delivery never hides them. `voice` is the project's voice id when this session started it, nil otherwise.
    public static func showsMood(voice: String?, voices: [VoiceEntry], advanced: Bool) -> Bool {
        var designed = false
        if let voice, let entry = voices.first(where: { $0.id == voice }), case .designed = entry.kind { designed = true }
        return SpeakControls.shown(engine: .studio, voiceIsDesigned: designed, advanced: advanced).contains(.mood)
    }

    /// The WAV of the variant the phrase plays now.
    public static func takeFile(of chunk: ProduceChunkDetail) -> String? {
        chunk.pick.flatMap { chunk.takeFiles[$0] }
    }

    /// The rows of a project's phrases, one per chunk the daemon renders (`GET /v1/produce/{id}/chunks`). The state is
    /// `PhraseScript.phraseStates` with each chunk as its own phrase; only a running project has a phrase being made.
    public static func rows(chunks: [ProduceChunkDetail], jobRunning: Bool) -> [PhraseRowValue] {
        let states = PhraseScript.phraseStates(
            emitting: Array(repeating: true, count: chunks.count),
            chunks: chunks.map { ProduceChunk(index: $0.index, status: $0.status) },
            paragraphOf: Dictionary(uniqueKeysWithValues: chunks.enumerated().map { ($0.element.index, $0.offset) }))
        return chunks.enumerated().map { offset, chunk in
            let state = states[offset]
            return PhraseRowValue(
                index: chunk.index,
                preview: PhraseScript.preview(chunk.text),
                state: !jobRunning && state == .rendering ? .pending : state,
                style: chunk.style,
                mood: mood(of: chunk.style),
                variant: chunk.pick.flatMap { chunk.takeKeys.firstIndex(of: $0) } ?? 0,
                variants: max(1, chunk.takeKeys.count),
                playable: takeFile(of: chunk) != nil)
        }
    }
}

/// One new variant of one phrase. The daemon renders it as a job, and a pick made before that job ends fails with "not one
/// of this chunk's takes": the new key does not exist yet. So the order is fixed: ask, wait until the project is idle,
/// read the chunk, and only then pick the key that is new, wait again (a pick re-assembles the track) and read the result.
public enum PhraseRegeneration {
    public struct Steps {
        /// Starts the render of one more variant of the chunk.
        public var regenerate: (Int) async throws -> Void
        /// Returns when the project's job has ended.
        public var waitUntilIdle: () async throws -> Void
        public var chunks: () async throws -> [ProduceChunkDetail]
        public var pick: (Int, String) async throws -> Void

        public init(regenerate: @escaping (Int) async throws -> Void, waitUntilIdle: @escaping () async throws -> Void,
                    chunks: @escaping () async throws -> [ProduceChunkDetail], pick: @escaping (Int, String) async throws -> Void) {
            self.regenerate = regenerate
            self.waitUntilIdle = waitUntilIdle
            self.chunks = chunks
            self.pick = pick
        }
    }

    /// The project's chunks after the new variant is the picked one (or as they are when no new variant appeared). `known`
    /// is the chunk's variant keys before the render: the new one is whichever key is not in it.
    public static func run(chunk: Int, known: [String], steps: Steps) async throws -> [ProduceChunkDetail] {
        let before = known
        try await steps.regenerate(chunk)
        try await steps.waitUntilIdle()
        let after = try await steps.chunks()
        guard let fresh = after.first(where: { $0.index == chunk })?.takeKeys.last(where: { !before.contains($0) }) else { return after }
        try await steps.pick(chunk, fresh)
        try await steps.waitUntilIdle()
        return try await steps.chunks()
    }
}

/// Waits for a project's job to end by asking the daemon for it; one lost answer does not end the wait.
public enum JobWait {
    public enum Failure: Error, Equatable { case gaveUp }

    /// The first terminal state of project `id`. `maxPolls` answers (or silences) later it gives up: a job that never ends
    /// must not hold a row busy for ever.
    public static func untilTerminal(id: String, poll: (String) async throws -> ProduceJob,
                                     sleep: (TimeInterval) async -> Void, interval: TimeInterval = 1,
                                     maxPolls: Int = 900) async throws -> ProduceJob {
        for attempt in 0..<maxPolls {
            if attempt > 0 { await sleep(interval) }
            if let job = try? await poll(id), job.status.isTerminal { return job }
        }
        throw Failure.gaveUp
    }
}
