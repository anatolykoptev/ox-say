/// What happens when a posted paste is over: the clipboard goes back to the
/// user and the outcome is reported. Lives here, not in PasteOutput, so the
/// decisions are testable against a fake pasteboard.
public enum PasteSettlement {
    /// - Parameters:
    ///   - read: an app read the promised clipboard before the cap.
    ///   - plain: writes the dictated text as ordinary clipboard text.
    ///   - onUnread: nothing read the dictation and the text is not on the
    ///     clipboard (the user's clipboard was put back, or was left alone as
    ///     theirs). The paste went nowhere; only the history has the text. `read` can be a false negative
    ///     (an app that pasted without reading the promise in time), which is
    ///     why the user's clipboard is NOT overwritten with the text here — the
    ///     notice says where to find it instead.
    public static func settle(lease: ClipboardLease, text: String, read: Bool, plain: DictationPasteboard,
                              onSettled: ((Bool) -> Void)?,
                              onNotice: ((String) -> Void)?, onUnread: (() -> Void)?) {
        onSettled?(read)
        let restored = lease.release()
        if !restored, let notice = lease.notice {
            // The user's clipboard is not coming back, so the dictation stays on
            // it. Write it plainly: the lent copy is a transient promise, which
            // clipboard history skips and which dies with this process.
            plain.writeText(text)
            onNotice?(notice)
        } else if !read {
            // Restored, or left alone because the user copied meanwhile or the
            // old copy was a secret: either way the dictation is on neither the
            // screen nor the clipboard.
            onUnread?()
        }
    }
}
