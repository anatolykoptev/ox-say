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
    ///   - selectedText: the AX read of the focused element, system-wide first and the frontmost app's own element when
    ///     that gave no text (`AXSelection.read`), with the outcome of every source it asked. A secure field
    ///     (subrole `AXSecureTextField`) is refused: its text is dropped and
    ///     ⌘C is never sent, the same outcome as `secureInput`. Nil or empty
    ///     text sends the plan toward the ⌘C fallback.
    ///   - secureInput: a password field is focused — synthetic keys go nowhere.
    ///   - postCopy: posts ⌘C to the frontmost app.
    ///   - spin: pumps the run loop briefly; the copy lands asynchronously.
    ///   - readText: the pasteboard's plain text, asked after the copy lands.
    ///   - copyTimeout: how long to wait for the copy.
    ///   - onSelection: called once per press with the path taken (ax, copy, remote, none) and every AX
    ///     source's result (never user content).
    public static func capture(board: DictationPasteboard,
                               selectedText: () -> AXSelection,
                               secureInput: () -> Bool,
                               postCopy: () -> Void,
                               spin: (TimeInterval) -> Void,
                               readText: () -> String?,
                               copyTimeout: TimeInterval = 0.4,
                               onSelection: ((SelectionReport) -> Void)? = nil) -> (text: String?, problem: String?) {
        let ax = selectedText()
        let (result, path) = run(ax: ax, board: board, secureInput: secureInput, postCopy: postCopy,
                                 spin: spin, readText: readText, copyTimeout: copyTimeout)
        onSelection?(SelectionReport(path: path, attempts: ax.attempts))
        return result
    }

    private static func run(ax: AXSelection,
                            board: DictationPasteboard,
                            secureInput: () -> Bool,
                            postCopy: () -> Void,
                            spin: (TimeInterval) -> Void,
                            readText: () -> String?,
                            copyTimeout: TimeInterval) -> (result: (text: String?, problem: String?), path: SelectionPath) {
        // AX is asked before the clipboard is looked at: when it hands over
        // the selection the clipboard is not touched at all, and on a
        // Universal Clipboard copy it is the only read that is safe — ⌘C
        // overwrites the copy and restoring needs the fetch from the phone.
        // A focused secure field is refused whole: its text is not returned and
        // ⌘C is not sent — the same outcome as the process-wide secure-input flag.
        let axText = ax.secureField ? nil : ax.text
        let secure = secureInput() || ax.secureField
        let snapshot = SelectionPolicy.needsClipboard(axText: axText, secureInput: secure)
            ? PasteboardSnapshot.capture(board, timeLimit: PasteboardSnapshot.readLimit) : nil
        switch SelectionPolicy.plan(axText: axText, secureInput: secure,
                                    clipboardRestorable: snapshot.map { $0.problems.isEmpty && !$0.isSensitive } ?? false,
                                    clipboardRemote: snapshot?.isRemote ?? false,
                                    axAnswered: ax.hasElement && ax.error == 0) {
        case .speak(let text): return ((text, nil), .ax)
        case .decline(let reason):
            // An iPhone copy is left alone: no ⌘C, no write, no read of its data.
            return ((nil, reason), snapshot?.isRemote == true ? .remote : .none)
        case .copy: break
        }
        // `.copy` is only planned when the snapshot was taken.
        guard let snapshot else { return ((nil, L10nKey.noticeSelectionFailed.text), .none) }
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
        // the other device); the plan never copies over one (#220).
        let afterCopy = board.changeCount
        defer { if !snapshot.isRemote && afterCopy != before && board.changeCount == afterCopy { board.restore(snapshot) } }
        guard afterCopy != before, let text = readText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ((nil, L10nKey.noticeSelectionNothing.text), .none)
        }
        return ((text, nil), .copy)
    }
}
