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
    ///     guarding one) has focus. Synthesized keystrokes must not go there, and
    ///     the text must not end up in it.
    ///   - accessibilityTrusted: `AXIsProcessTrusted()`: posting Cmd+V to another
    ///     app needs the Accessibility permission.
    public static func decide(secureInput: Bool, accessibilityTrusted: Bool) -> Delivery {
        if secureInput {
            return .clipboardOnly(reason: "A password field has focus, so the text was not pasted. It is on the clipboard.")
        }
        if !accessibilityTrusted {
            return .clipboardOnly(reason: "Pasting needs the Accessibility permission (System Settings → Privacy & Security → Accessibility). The text is on the clipboard.")
        }
        return .paste
    }
}
