/// Holds a notice back while a dictation runs. The pill, the beep and the
/// status line belong to the dictation from the key down until it is idle
/// again: a notice that lands in between — an unread paste of the PREVIOUS
/// dictation settling after its 3 s cap, a failed speak request, a shortcut
/// conflict — must not replace the Listening pill, beep into the microphone or
/// leave a 4 s message timer fighting the dictation's pill.
///
/// One notice is kept, because the pill only ever shows one message. A newer
/// one replaces it unless the kept one ranks higher (`Priority`): the app's own
/// state (`endedReason`, the history) outlives a dropped message, but a lost
/// text's notice is the only thing that says where the text went.
public struct NoticeGate {
    /// What a notice costs the user when it is lost. A held notice is only
    /// replaced by one of equal or higher rank.
    public enum Priority: Int, Comparable {
        /// Said once and repeated by the app itself: a new release (the menu
        /// row and the dot still offer it, and the check raises it again).
        case low = 0
        /// Settings, shortcuts, permissions, a delivery caveat or an error.
        case normal = 1
        /// Text the user dictated went nowhere they can see (an unread paste):
        /// the notice is the only pointer to where it is.
        case lostText = 2

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Notice: Equatable {
        public let message: String
        public let kind: DictationNotice.Kind
        public let priority: Priority
        /// The release tag this notice announces; remembered as told only once
        /// the notice is actually shown (`AutoUpdateSchedule.noticeShown`).
        public let announces: String?

        public init(message: String, kind: DictationNotice.Kind, priority: Priority = .normal,
                    announces: String? = nil) {
            self.message = message
            self.kind = kind
            self.priority = priority
            self.announces = announces
        }

        /// The previous dictation's paste that no app read. It is about THAT
        /// dictation, so it is `.unrelated`: a later dictation's `endedReason`
        /// must not be prefixed onto it.
        public static func unreadPaste(_ message: String) -> Notice {
            Notice(message: message, kind: .unrelated, priority: .lostText)
        }

        /// The clipboard could not be put back once the paste settled, seconds
        /// after delivery. It is about the paste that already happened, not
        /// about the dictation now running or the next one, so it is
        /// `.unrelated`: a later dictation's `endedReason` must not be spent
        /// on it.
        public static func lateClipboard(_ message: String) -> Notice {
            Notice(message: message, kind: .unrelated)
        }

        /// A newer release was found.
        public static func updateAvailable(_ message: String, tag: String) -> Notice {
            Notice(message: message, kind: .unrelated, priority: .low, announces: tag)
        }

        /// A click on the update row that a running dictation refused: the
        /// answer to something the user just did, so it ranks `.normal`.
        public static func updateRefused(_ message: String) -> Notice {
            Notice(message: message, kind: .unrelated)
        }
    }

    /// The notice waiting for the dictation to end.
    public private(set) var pending: Notice?

    public init() {}

    /// The notice to show right now, or nil when it was kept for later
    /// (`release` hands it back once idle).
    public mutating func admit(_ notice: Notice, state: DictationState) -> Notice? {
        guard state == .idle else {
            if let held = pending, held.priority > notice.priority { return nil }
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
