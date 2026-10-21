/// Holds a notice back while a dictation runs. The pill, the beep and the
/// status line belong to the dictation from the key down until it is idle
/// again: a notice that lands in between — an unread paste of the PREVIOUS
/// dictation settling after its 3 s cap, a failed speak request, a shortcut
/// conflict — must not replace the Listening pill, beep into the microphone or
/// leave a 4 s message timer fighting the dictation's pill.
///
/// One notice is kept. A newer one replaces it: the pill only ever shows one
/// message, so showing both in a row would have shown just the second anyway,
/// and the app's own state (`endedReason`, the history) outlives the message.
public struct NoticeGate {
    public struct Notice: Equatable {
        public let message: String
        public let kind: DictationNotice.Kind

        public init(message: String, kind: DictationNotice.Kind) {
            self.message = message
            self.kind = kind
        }
    }

    /// The notice waiting for the dictation to end.
    public private(set) var pending: Notice?

    public init() {}

    /// The notice to show right now, or nil when it was kept for later
    /// (`release` hands it back once idle).
    public mutating func admit(_ notice: Notice, state: DictationState) -> Notice? {
        guard state == .idle else {
            pending = notice
            return nil
        }
        return notice
    }

    /// The kept notice, once nothing dictates; nil while a dictation still
    /// runs or when nothing waits.
    public mutating func release(state: DictationState) -> Notice? {
        guard state == .idle, let held = pending else { return nil }
        pending = nil
        return held
    }
}
