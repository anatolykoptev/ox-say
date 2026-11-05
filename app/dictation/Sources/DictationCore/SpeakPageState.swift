import Foundation

/// Whether the daemon answered the last time the page asked.
public enum DaemonReach: Equatable { case unknown, reachable, unreachable(String) }

public enum SpeakPhase: Equatable { case idle, generating, ready, failed(String) }

extension SpeakPhase {
    /// Choosing another clip while a take is being made would silently drop that take.
    public var allowsSelection: Bool {
        if case .generating = self { return false }
        return true
    }
}

/// A problem with the text that is known before any request, in the sentence the person reads.
public enum SpeakInputCheck {
    /// nil when the text can be voiced on `engine`. Lengths are Unicode scalars of the string that is
    /// sent, the way the daemon counts runes: the fast voice sends the text as typed
    /// (`SpeechClient.maxInputChars`), the studio voice the trimmed script (`ProduceRequest.scriptLimit`).
    public static func problem(_ text: String, engine: SpeakEngine, text t: (L10nKey) -> String) -> String? {
        if ScriptLimit.script(from: text).isEmpty { return t(.speakProblemEmpty) }
        switch engine {
        case .fast:
            let cap = SpeechClient.maxInputChars
            return text.unicodeScalars.count > cap ? String(format: t(.speakProblemTooLong), String(cap)) : nil
        case .studio:
            let cap = ProduceRequest.scriptLimit
            return ScriptLimit.overBy(ScriptLimit.script(from: text)) > 0 ? String(format: t(.speakProblemTooLong), String(cap)) : nil
        }
    }
}

/// What the Озвучка page shows. One decision, like `VoicesPageState`.
public enum SpeakPageState: Equatable {
    /// The daemon is not answering; nothing else is worth showing.
    case offline(String)
    /// The editor, with the problem under it when the text cannot be voiced.
    case editing(problem: String?)
    case generating(progress: Double?)
    case ready
    case failed(String)

    public static func of(reach: DaemonReach, problem: String?, phase: SpeakPhase) -> SpeakPageState {
        if case .unreachable(let sentence) = reach { return .offline(sentence) }
        switch phase {
        case .generating: return .generating(progress: nil)
        case .failed(let sentence): return .failed(sentence)
        case .ready: return .ready
        case .idle: return .editing(problem: problem)
        }
    }
}
