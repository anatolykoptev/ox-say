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

    /// The message to show and the ended-reason still pending after it. An
    /// `outcome` notice takes the reason as its prefix and spends it; an
    /// `unrelated` one leaves both alone.
    public static func merge(endedReason: String?, into message: String, kind: Kind)
        -> (message: String, endedReason: String?) {
        guard kind == .outcome, let endedReason else { return (message, endedReason) }
        return ("\(endedReason) \(message)", nil)
    }
}
