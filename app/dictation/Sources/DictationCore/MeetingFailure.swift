import Foundation

/// Why a meeting or its notes failed, as a sentence. The daemon records a stable code (`fail_reason`, the `Fail*`
/// constants of internal/meeting/fail_reason.go) beside its English text, which names internals and is for the log
/// only. A code this app does not know, or none (a failure recorded before codes), gets the general sentence.
public enum MeetingFailure {
    /// `notes` is false for a recording that failed before its transcript, true for notes that could not be written.
    public static func key(code: String?, notes: Bool) -> L10nKey {
        if notes {
            switch code {
            case "notes_engine_start": return .meetingNotesEngineStart
            case "notes_engine_verify": return .meetingNotesEngineVerify
            case "notes_engine_timeout": return .meetingNotesEngineTimeout
            case "notes_empty": return .meetingNotesEmpty
            case "notes_failed": return .meetingNotesFailed
            case "storage": return .meetingNotesStorage
            default: return .meetingNotesFailed
            }
        }
        switch code {
        case "speech_model_missing": return .meetingFailedSpeechModel
        case "speech_busy": return .meetingFailedSpeechBusy
        case "speech_failed": return .meetingFailedSpeech
        case "no_transcript": return .meetingFailedNoTranscript
        case "storage": return .meetingFailedStorage
        default: return .meetingFailedGeneric
        }
    }
}
