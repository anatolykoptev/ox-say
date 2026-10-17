import Foundation

/// What a phrase row shows about its own work.
public enum PhraseState: Equatable {
    /// No chunk of it exists yet (or it emits none — see `ReelScript.emits`).
    case pending
    /// It holds the chunk the daemon is rendering: the lowest-index open one.
    case rendering
    /// Every chunk of it passed.
    case done
    /// One of its chunks is left for a listen (the daemon's "review"): it has
    /// audio — the best take the checks could not pass.
    case needsListen
}

/// A phrase row: its number, a short preview and how far it is.
public struct PhraseRow: Equatable, Identifiable {
    public var index: Int
    public var preview: String
    public var state: PhraseState

    public var id: Int { index }

    public init(index: Int, preview: String, state: PhraseState) {
        self.index = index
        self.preview = preview
        self.state = state
    }
}

/// The Reel editor's rules: the script's phrases are the daemon's paragraphs,
/// and per-phrase progress is the daemon's chunks mapped back through their
/// paragraph index. Everything here is pure; the window only draws it.
public enum ReelScript {
    /// The create the plan pins: one take per chunk and the reference clone
    /// path (designed voices with a reference text resolve "ultimate" under
    /// auto, and per-phrase emotions need reference).
    public static let takes = 1
    public static let cloneMode = "reference"

    /// How much of a phrase a row shows.
    public static let previewLength = 60

    /// The script's phrases: its blank-line-separated paragraphs, trimmed,
    /// empty ones dropped — vscript paragraphs(). The editor is the phrase
    /// editor; there are no per-phrase controls.
    public static func phrases(of script: String) -> [String] {
        let lines = script.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var phrases: [String] = []
        var current: [String] = []
        func flush() {
            let phrase = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { phrases.append(phrase) }
            current = []
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return phrases
    }

    /// Whether the daemon gives this phrase any chunks. A paragraph of nothing
    /// but `[pause …]` directives emits none and does not take a paragraph
    /// number (vscript/markup.go `Parse`: `para` advances only past a block
    /// that emitted), so the phrase→paragraph map must skip it the same way.
    public static func emits(_ phrase: String) -> Bool {
        let stripped = phrase.replacingOccurrences(of: ScriptBrackets.directivePattern,
                                                   with: "", options: .regularExpression)
        return !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The create's title: the first phrase with its line breaks folded; the
    /// daemon keeps the first 60 runes of it (produce.go titleRunes).
    public static func title(of script: String) -> String {
        fold(phrases(of: script).first ?? "")
    }

    /// A row's preview: the phrase's start, whitespace folded, capped.
    /// Directives ([pause …], [style: …]) are the daemon's, not the reader's —
    /// the row shows only the spoken words, stripped the way `emits` strips.
    public static func preview(_ phrase: String) -> String {
        let words = phrase.replacingOccurrences(of: ScriptBrackets.directivePattern,
                                                with: "", options: .regularExpression)
        let folded = fold(words)
        guard folded.count > previewLength else { return folded }
        return String(folded.prefix(previewLength)) + "…"
    }

    /// Line breaks and runs of spaces read as one space.
    private static func fold(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "1:01" / "1:01:01" for the result block; nil while the job reports none.
    public static func durationText(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        let whole = Int(seconds)
        if whole >= Self.secondsPerHour {
            return String(format: "%d:%02d:%02d", whole / Self.secondsPerHour,
                          whole / Self.secondsPerMinute % Self.secondsPerMinute, whole % Self.secondsPerMinute)
        }
        return String(format: "%d:%02d", whole / Self.secondsPerMinute, whole % Self.secondsPerMinute)
    }

    private static let secondsPerMinute = 60
    private static let secondsPerHour = 60 * secondsPerMinute

    /// The chunk indices of a followed job still missing a fetched detail —
    /// what the next sync must ask the daemon for, one round per poll. A job
    /// is synced exactly when this is empty: a detail fetch that failed leaves
    /// its index here and is retried on the next status poll.
    public static func missingChunks(of job: ProduceJob, paragraphOf: [Int: Int]) -> [Int] {
        (0..<job.partsTotal).filter { paragraphOf[$0] == nil }
    }

    /// "Озвучить" may be pressed: the text fits, the studio voice can run, and
    /// no voiceover is going. One project at a time.
    public static func canCreate(script: String, studioAvailable: Bool, jobRunning: Bool) -> Bool {
        ScriptLimit.canStart(editorText: script) && studioAvailable && !jobRunning
    }

    /// Each phrase's state from the daemon's chunks. `emitting[i]` says phrase
    /// i has spoken text (`emits`); the daemon numbers only such phrases.
    /// `paragraphOf` maps a chunk index to that numbering — from
    /// `GET /v1/produce/{id}/chunks/{n}`, the only place the summary's chunk
    /// list lacks it. A phrase is done when every chunk of its paragraph is;
    /// a "review" chunk fails it; the one holding the lowest-index open chunk
    /// is rendering — the daemon works through them in order.
    public static func phraseStates(emitting: [Bool], chunks: [ProduceChunk], paragraphOf: [Int: Int]) -> [PhraseState] {
        let firstOpen = chunks.filter { $0.status.isOpen }.map(\.index).min().flatMap { paragraphOf[$0] }
        var emitted = 0
        return emitting.map { hasText in
            guard hasText else { return .pending }
            let paragraph = emitted
            emitted += 1
            let own = chunks.filter { paragraphOf[$0.index] == paragraph }
            guard !own.isEmpty else { return .pending }
            if own.contains(where: { $0.status == .review }) { return .needsListen }
            if own.allSatisfy({ $0.status == .ok }) { return .done }
            return paragraph == firstOpen ? .rendering : .pending
        }
    }
}
