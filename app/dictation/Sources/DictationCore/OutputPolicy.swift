/// How dictated text reaches the user.
public enum Delivery: Equatable {
    /// Borrow the clipboard, send Cmd+V to the frontmost app, restore the clipboard.
    case paste
    /// Leave the text on the clipboard and tell the user why it was not pasted.
    case clipboardOnly(reason: String)
}

public enum OutputPolicy {
    /// Decides how to deliver dictated text.
    /// - Parameters:
    ///   - secureInput: `IsSecureEventInputEnabled()`: a password field (or an app
    ///     guarding one, or Terminal's Secure Keyboard Entry) has the keyboard.
    ///     Synthesized keystrokes must not go there, and the text must not end up in it.
    ///   - focusMoved: the frontmost app is not the one that had focus when the
    ///     recording stopped. Pasting would put the text somewhere the user did
    ///     not dictate into.
    ///   - accessibilityTrusted: `AXIsProcessTrusted()`: posting Cmd+V to another
    ///     app needs the Accessibility permission.
    public static func decide(secureInput: Bool, focusMoved: Bool = false, accessibilityTrusted: Bool) -> Delivery {
        if secureInput {
            return .clipboardOnly(reason: "Secure input is on (a password field, or Secure Keyboard Entry), so the text was not pasted. It is on the clipboard.")
        }
        if focusMoved {
            return .clipboardOnly(reason: "You switched apps while it was transcribing, so the text was not pasted. It is on the clipboard.")
        }
        if !accessibilityTrusted {
            return .clipboardOnly(reason: "Pasting needs the Accessibility permission (System Settings → Privacy & Security → Accessibility). The text is on the clipboard.")
        }
        return .paste
    }
}
