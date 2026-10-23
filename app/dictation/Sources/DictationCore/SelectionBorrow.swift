import Foundation

/// The speak-selection capture driver: ask AX for the selection first — it
/// reads the selection without touching the clipboard — then fall back to a
/// ⌘C borrow when the policy allows. Lives here so the whole flow runs against
/// a fake pasteboard in tests; the platform seams (the AX read, the
/// secure-input flag, the ⌘C post, the run-loop spin the copy lands through,
/// the clipboard read-back) are parameters.
public enum SelectionBorrow {
    /// The selected text, or why it could not be read.
    /// - Parameters:
    ///   - board: the general pasteboard.
    ///   - selectedText: the focused element's AXSelectedText; nil or blank
    ///     sends the plan toward the ⌘C fallback.
    ///   - secureInput: a password field is focused — synthetic keys go nowhere.
    ///   - postCopy: posts ⌘C to the frontmost app.
    ///   - spin: pumps the run loop briefly; the copy lands asynchronously.
    ///   - readText: the pasteboard's plain text, asked after the copy lands.
    ///   - copyTimeout: how long to wait for the copy.
    ///   - onRemoteCopy: called once when a ⌘C result lands over a Universal
    ///     Clipboard copy — that copy is gone and cannot be put back, which is
    ///     worth a log line (never user content).
    public static func capture(board: DictationPasteboard,
                               selectedText: () -> String?,
                               secureInput: () -> Bool,
                               postCopy: () -> Void,
                               spin: (TimeInterval) -> Void,
                               readText: () -> String?,
                               copyTimeout: TimeInterval = 0.4,
                               onRemoteCopy: (() -> Void)? = nil) -> (text: String?, problem: String?) {
        // AX is asked before the clipboard is looked at: when it hands over
        // the selection the clipboard is not touched at all, and on a
        // Universal Clipboard copy it is the only read that is safe — ⌘C
        // overwrites the copy and restoring needs the fetch from the phone.
        let ax = selectedText()
        let secure = secureInput()
        let snapshot = SelectionPolicy.needsClipboard(axText: ax, secureInput: secure)
            ? PasteboardSnapshot.capture(board) : nil
        switch SelectionPolicy.plan(axText: ax, secureInput: secure,
                                    clipboardRestorable: snapshot.map { $0.problems.isEmpty && !$0.isSensitive } ?? false,
                                    clipboardRemote: snapshot?.isRemote ?? false) {
        case .speak(let text): return (text, nil)
        case .decline(let reason): return (nil, reason)
        case .copy: break
        }
        // `.copy` is only planned when the snapshot was taken.
        guard let snapshot else { return (nil, "The selection did not come through.") }
        let before = board.changeCount
        postCopy()
        // The copy lands on the pasteboard asynchronously; a selection-less
        // ⌘C changes nothing and simply times out.
        let deadline = Date().addingTimeInterval(copyTimeout)
        while board.changeCount == before && Date() < deadline {
            spin(0.01)
        }
        // Restore only our own copy: nothing copied → nothing to put back;
        // a newer clipboard is the user's and restoring would destroy it.
        // A remote snapshot holds nothing (restoring would need the fetch from
        // the other device): the clipboard keeps the selection.
        let afterCopy = board.changeCount
        defer { if !snapshot.isRemote && afterCopy != before && board.changeCount == afterCopy { board.restore(snapshot) } }
        if snapshot.isRemote, afterCopy != before { onRemoteCopy?() }
        guard afterCopy != before, let text = readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, "Nothing selected to speak.")
        }
        return (text, nil)
    }
}
