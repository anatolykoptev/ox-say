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
/// would destroy the user's clipboard silently.
public enum SelectionPolicy {
    public static func plan(axText: String?, secureInput: Bool, clipboardRestorable: Bool) -> SelectionPlan {
        if let axText, !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .speak(axText)
        }
        if secureInput {
            return .decline("A password field is focused.")
        }
        guard clipboardRestorable else {
            return .decline("The selection did not come through.")
        }
        return .copy
    }
}
