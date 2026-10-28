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
            case "disk_full": return .meetingNotesDiskFull
            default: return .meetingNotesFailed
            }
        }
        switch code {
        case "speech_model_missing": return .meetingFailedSpeechModel
        case "speech_busy": return .meetingFailedSpeechBusy
        case "speech_failed": return .meetingFailedSpeech
        case "no_transcript": return .meetingFailedNoTranscript
        case "storage": return .meetingFailedStorage
        case "disk_full": return .meetingFailedDiskFull
        default: return .meetingFailedGeneric
        }
    }
}

extension MeetingFailure {
    /// The same sentence without "press Try Again", for a failure the window offers no retry for (the audio was deleted
    /// by retention, which also deletes the audio of failed meetings). A sentence that already gives no such advice is
    /// returned as it is.
    static func withoutRetryAdvice(_ key: L10nKey) -> L10nKey {
        switch key {
        case .meetingFailedSpeechBusy: return .meetingFailedSpeechBusyFinal
        case .meetingFailedSpeech: return .meetingFailedSpeechFinal
        case .meetingFailedNoTranscript: return .meetingFailedNoTranscriptFinal
        case .meetingFailedStorage: return .meetingFailedStorageFinal
        case .meetingFailedDiskFull: return .meetingFailedDiskFullFinal
        case .meetingFailedGeneric: return .meetingFailedGenericFinal
        default: return key
        }
    }
}

/// What the window shows for a meeting that failed, and the one thing the user can do about it. Both a recording that
/// did not finish (`.failed`) and notes that could not be written (`.transcribed` with `notes_pending` "failed") come
/// through here, so the header, the notes callout and the list agree and no view picks a sentence of its own.
public struct MeetingFailureNotice: Equatable {
    /// The app's own sentence for the daemon's code, in the user's language.
    public var sentence: String
    /// True for failed notes (the callout where the notes would be), false for a recording that did not finish (the header).
    public var notes: Bool
    /// "Try Again" is offered: POST /v1/meetings/{id}/notes, which the daemon's Retry answers for a failed recording
    /// (from its transcript when one stands, else from its audio) and for failed notes. Not offered when it cannot help:
    /// the audio is gone, or the speech model is missing (the daemon finishes the recording by itself once it is installed).
    public var canRetry: Bool

    /// What a finished meeting that failed announces (the pill, the menu's status line): the sentence of `of`, never the
    /// daemon's own text. nil when nothing failed.
    public static func announcement(for info: MeetingInfo, text: (L10nKey) -> String = { $0.text }) -> String? {
        of(info, text: text)?.sentence
    }

    public static func of(_ info: MeetingInfo, text: (L10nKey) -> String = { $0.text }) -> MeetingFailureNotice? {
        switch info.status {
        case .failed:
            let waitsForModel = info.failReason == "speech_model_missing"
            let canRetry = !info.audioDeleted && !waitsForModel
            // Where there is no button, the sentence gives no advice that points to one.
            let key = MeetingFailure.key(code: info.failReason, notes: false)
            return MeetingFailureNotice(sentence: text(canRetry ? key : MeetingFailure.withoutRetryAdvice(key)), notes: false,
                                        canRetry: canRetry)
        case .transcribed:
            guard info.notesPending == "failed" else { return nil }
            return MeetingFailureNotice(sentence: text(MeetingFailure.key(code: info.failReason, notes: true)), notes: true, canRetry: true)
        default:
            return nil
        }
    }
}
