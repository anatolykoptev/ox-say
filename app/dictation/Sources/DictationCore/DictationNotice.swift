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

    /// The held notice released when a dictation turns idle, with the pending
    /// ended-reason resolved into it. The pill holds one message, so the two
    /// can only be said as one: the reason prefixes the released notice — the
    /// same shape `merge` gives an outcome notice — and is spent. The
    /// exception is a `.lostText` release, the only pointer to a text that
    /// went nowhere: an informational reason is dropped rather than crowding
    /// it — never kept, or a stale one would prefix a later dictation's own
    /// outcome notice.
    public static func released(_ held: NoticeGate.Notice, flushing endedReason: String?)
        -> (notice: NoticeGate.Notice, endedReason: String?) {
        guard held.priority != .lostText else { return (held, nil) }
        guard let endedReason else { return (held, nil) }
        return (NoticeGate.Notice(message: "\(endedReason) \(held.message)", kind: held.kind,
                                priority: held.priority, announces: held.announces), nil)
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
