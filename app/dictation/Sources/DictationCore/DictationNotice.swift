/// The pending reason a self-ended recording (length cap, microphone change)
/// earns: said once, as the prefix of the notice that says what happened to
/// ITS text — and spent on nothing else. An unrelated notice raised while a
/// capped recording is still transcribing shows untouched and leaves the
/// reason pending for the dictation's own outcome.
public enum DictationNotice {
    /// Whether a notice reports on the dictation that ended.
    public enum Kind: Equatable {
        /// What became of its text: a delivery caveat or the error that
        /// replaced it.
        case outcome
        /// Settings, shortcuts, permissions — anything but that dictation.
        case unrelated
    }

    /// What to say of an ended-reason still pending when a dictation turns idle,
    /// after the held notice was released: nothing when that notice was shown
    /// (`releasedNotice`). The pill holds one message and a lost-text pointer
    /// must not be overwritten in the same tick; the reason is informational and
    /// is dropped, never kept — a stale one would prefix a later dictation's
    /// own outcome notice.
    public static func reasonToFlush(_ endedReason: String?, releasedNotice: Bool) -> String? {
        releasedNotice ? nil : endedReason
    }

    /// The message to show and the ended-reason still pending after it. An
    /// `outcome` notice takes the reason as its prefix and spends it; an
    /// `unrelated` one leaves both alone.
    public static func merge(endedReason: String?, into message: String, kind: Kind)
        -> (message: String, endedReason: String?) {
        guard kind == .outcome, let endedReason else { return (message, endedReason) }
        return ("\(endedReason) \(message)", nil)
    }
}
