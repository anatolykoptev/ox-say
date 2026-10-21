/// What happens when a posted paste is over: the clipboard goes back to the
/// user and the outcome is reported. Lives here, not in PasteOutput, so the
/// decisions are testable against a fake pasteboard.
public enum PasteSettlement {
    /// - Parameters:
    ///   - read: an app read the promised clipboard before the cap.
    ///   - plain: writes the dictated text as ordinary clipboard text.
    ///   - onUnread: the user's clipboard was put back and nothing read the
    ///     dictation. The paste went nowhere AND the text is not on the
    ///     clipboard; only the history has it. `read` can be a false negative
    ///     (an app that pasted without reading the promise in time), which is
    ///     why the user's clipboard is NOT overwritten with the text here — the
    ///     notice says where to find it instead.
    public static func settle(lease: ClipboardLease, text: String, read: Bool, plain: DictationPasteboard,
                              onSettled: ((Bool) -> Void)?, onRemoteClipboardKept: (() -> Void)?,
                              onNotice: ((String) -> Void)?, onUnread: (() -> Void)?) {
        onSettled?(read)
        let restored = lease.release()
        if lease.keptRemote {
            plain.writeText(text)
            onRemoteClipboardKept?()
        } else if !restored, let notice = lease.notice {
            // The user's clipboard is not coming back, so the dictation stays on
            // it. Write it plainly: the lent copy is a transient promise, which
            // clipboard history skips and which dies with this process.
            plain.writeText(text)
            onNotice?(notice)
        } else if restored && !read {
            onUnread?()
        }
    }
}
