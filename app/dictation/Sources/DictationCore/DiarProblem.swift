import Foundation

/// Why the far side of a meeting has one label although the daemon was to tell its voices apart. The daemon records
/// it in the meeting: `warnings` holds `diarization_unavailable` or `diarization_failed`, and `diar_reason` the code.
public enum DiarProblem: Equatable {
    /// This Mac cannot do it (an old macOS, an unsupported processor, no engine or models) or the recording is too
    /// long for it (over two hours). Nothing was tried, and trying again cannot help.
    case unavailable(reason: String)
    /// The voice engine ran and broke. Trying again can help, except after a timeout: the same call would take as long
    /// again, and a retry transcribes it a second time first.
    case failed(reason: String)

    public static func of(warnings: [String], reason: String?) -> DiarProblem? {
        if warnings.contains("diarization_failed") { return .failed(reason: reason ?? "") }
        if warnings.contains("diarization_unavailable") { return .unavailable(reason: reason ?? "") }
        return nil
    }

    public var canRetry: Bool {
        if case .failed(let reason) = self { return reason != "timeout" }
        return false
    }

    /// Whether the app offers "Try Again" for this problem on a meeting. A failed run is the app's own rule (`canRetry`).
    /// An unavailable one is the daemon's: it alone knows whether diarization is ready now and whether the recording can
    /// still be transcribed (`voices_retryable`), so a reason is never judged here; without that word nothing is offered,
    /// because pressing it could only fail again. A recording retention removed has nothing to transcribe in either case.
    public func offersRetry(daemonSaysRetryable: Bool, audioDeleted: Bool) -> Bool {
        if audioDeleted { return false }
        switch self {
        case .failed: return canRetry
        case .unavailable: return daemonSaysRetryable
        }
    }

    /// The sentence for the menu. A code this app does not know gets the general sentence of its kind, so a newer
    /// daemon never shows an empty row.
    public var messageKey: L10nKey {
        switch self {
        case .failed(let reason):
            switch reason {
            case "engine_error": return .diarFailedEngine
            case "bad_output": return .diarFailedOutput
            case "timeout": return .diarFailedTimeout
            default: return .diarFailedEngine
            }
        case .unavailable(let reason):
            switch reason {
            case "os_too_old": return .diarUnavailableOS
            case "cpu_unsupported": return .diarUnavailableCPU
            case "engine_missing": return .diarUnavailableEngine
            case "models_missing": return .diarUnavailableModels
            case "models_unusable": return .diarUnavailableUnusable
            case "too_long": return .diarUnavailableTooLong
            case "input_unreadable": return .diarUnavailableUnreadable
            default: return .diarUnavailableOther
            }
        }
    }
}
