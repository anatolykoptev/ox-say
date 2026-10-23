import Foundation

/// What pressing the speak-selection key should do next, given what the
/// accessibility tree and the clipboard allow.
public enum SelectionPlan: Equatable {
    /// AX handed over the selection: speak it.
    case speak(String)
    /// AX gave nothing: borrow the clipboard and send ⌘C.
    case copy
    /// Nothing safe to do; tell the user why.
    case decline(String)
}

/// The speak-selection capture policy. AX is asked first: it reads the
/// selection without touching anything. ⌘C follows only when no secure field
/// is focused and the clipboard snapshot can be put back — a snapshot with
/// problems or a secret inside is not safely restorable, so copying over it
/// would destroy the user's clipboard silently. A remote (Universal Clipboard)
/// clipboard is the exception: it is never read, so it cannot be restored, but
/// declining would make speak-selection stop working after every iPhone copy —
/// the copy proceeds and the clipboard is left holding the selection, as
/// dictation leaves its text.
public enum SelectionPolicy {
    /// Every caller must say whether the clipboard held a Universal Clipboard
    /// copy — the same reason `OutputPolicy.decide` has no default: a forgotten
    /// flag reads as "local", and the risky copy proceeds without a word.
    public static func plan(axText: String?, secureInput: Bool, clipboardRestorable: Bool,
                            clipboardRemote: Bool) -> SelectionPlan {
        if let axText, !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .speak(axText)
        }
        if secureInput {
            return .decline("A password field is focused.")
        }
        // AX answered with a selection that is only whitespace: the app has
        // said what is selected, and ⌘C would copy the same blanks. An empty
        // string stays ambiguous (no selection, or an app whose AX does not
        // know), so it still falls through to the copy.
        if isWhitespaceOnly(axText) {
            return .decline("Nothing selected to speak.")
        }
        guard clipboardRestorable || clipboardRemote else {
            return .decline("The selection did not come through.")
        }
        return .copy
    }

    /// Whether `plan` can reach the clipboard checks at all — AX gave nothing
    /// usable and no secure field is focused. Lets the caller skip reading the
    /// clipboard on the paths that never look at it. Mirrors the checks above;
    /// if their order changes, this changes with them.
    public static func needsClipboard(axText: String?, secureInput: Bool) -> Bool {
        if let axText, !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return !secureInput && !isWhitespaceOnly(axText)
    }

    /// Non-empty text with nothing in it but whitespace.
    private static func isWhitespaceOnly(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
