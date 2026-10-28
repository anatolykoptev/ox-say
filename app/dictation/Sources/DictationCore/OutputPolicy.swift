/// Why dictated text stayed on the clipboard instead of being pasted: `code`
/// is the stable token the timing line logs as `clipboard_reason=` (something
/// may parse it — the values do not change), `message` is what the user sees.
public enum ClipboardReason: Equatable {
    /// No working Accessibility grant: a synthesized Cmd+V is silently dropped.
    /// The grant can be stale — recorded for a differently-signed build — in
    /// which case the "Allow pasting…" menu item resets this app's entry.
    case accessibility
    /// A password field (or an app guarding one, or Terminal's Secure Keyboard
    /// Entry) has the keyboard.
    case secureInput
    /// The frontmost app is not the one that had focus when recording stopped.
    case focusMoved

    /// The timing line's `clipboard_reason=` value.
    public var code: String {
        switch self {
        case .accessibility: return "accessibility"
        case .secureInput: return "secure_input"
        case .focusMoved: return "focus_moved"
        }
    }

    /// The notice shown when the text stays on the clipboard.
    public func message(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .accessibility: return text(.noticePasteAccessibility)
        case .secureInput: return text(.noticePasteSecureInput)
        case .focusMoved: return text(.noticePasteFocusMoved)
        }
    }
}

/// How dictated text reaches the user.
public enum Delivery: Equatable {
    /// Borrow the clipboard, send Cmd+V to the frontmost app, restore the clipboard.
    case paste
    /// Type the text into the app with synthetic key events carrying Unicode
    /// strings: the clipboard is left untouched, so a copy made on another
    /// device (Universal Clipboard) survives the dictation.
    case typed
    /// Leave the text on the clipboard and tell the user why it was not pasted.
    case clipboardOnly(reason: ClipboardReason)
}

public enum OutputPolicy {
    /// The frontmost app is not the one that had focus when the recording stopped (`target`; nil when none was
    /// recorded). One rule for the check before the clipboard wait and the one after it.
    public static func focusMoved(target: Int32?, front: Int32?) -> Bool {
        target != nil && front != target
    }

    /// Decides how to deliver dictated text.
    /// - Parameters:
    ///   - secureInput: `IsSecureEventInputEnabled()`: a password field (or an app
    ///     guarding one, or Terminal's Secure Keyboard Entry) has the keyboard.
    ///     Synthesized keystrokes must not go there, and the text must not end up in it.
    ///   - focusMoved: the frontmost app is not the one that had focus when the
    ///     recording stopped. Pasting would put the text somewhere the user did
    ///     not dictate into.
    ///   - accessibilityTrusted: `AXIsProcessTrusted()`: posting synthesized keys
    ///     to another app needs the Accessibility permission.
    ///   - clipboardRemote: an item on the clipboard declares a Universal
    ///     Clipboard copy (checked on declared types only — never read). A paste
    ///     would overwrite it, and it cannot be put back without fetching it
    ///     from the other device, so the text is typed instead. No default: a
    ///     caller that forgets it silently brings back the destroyed copy.
    public static func decide(secureInput: Bool, focusMoved: Bool = false, accessibilityTrusted: Bool,
                              clipboardRemote: Bool) -> Delivery {
        if secureInput {
            return .clipboardOnly(reason: .secureInput)
        }
        if focusMoved {
            return .clipboardOnly(reason: .focusMoved)
        }
        if !accessibilityTrusted {
            return .clipboardOnly(reason: .accessibility)
        }
        return clipboardRemote ? .typed : .paste
    }
}
