import CoreGraphics

/// ⌘V must press the key that types "v" with ⌘ held, not the QWERTY V
/// position: on Dvorak the QWERTY V key is "k", and the letter v sits on the
/// QWERTY "." key. Layouts switch tables under ⌘: Russian, Ukrainian, Hebrew and
/// the other non-Latin layouts type QWERTY Latin with ⌘ held, and "Dvorak –
/// QWERTY ⌘" types QWERTY, so a scan under ⌘ finds the right key for each.
public enum PasteKey {
    /// kVK_ANSI_V as a plain number: DictationCore does not link Carbon.
    public static let ansiV = 9
    /// kVK_ANSI_C as a plain number.
    public static let ansiC = 8

    /// The virtual key code that types "v" with ⌘ held in the current keyboard
    /// layout: the lowest code in 0–127 whose `lookup` says so, else `ansiV`.
    /// In the app `lookup` is UCKeyTranslate with the ⌘ modifier on the live
    /// layout, which also covers "Dvorak – QWERTY ⌘" (QWERTY under ⌘) and
    /// Russian (Latin under ⌘); in tests it is a table.
    public static func commandV(lookup: (Int) -> Character?) -> Int {
        for code in 0...127 where lookup(code) == "v" {
            return code
        }
        return ansiV
    }

    /// The virtual key code that types "c" with ⌘ held: the same scan for the
    /// speak-selection copy. kVK_ANSI_C types "i" on Dvorak.
    public static func commandC(lookup: (Int) -> Character?) -> Int {
        for code in 0...127 where lookup(code) == "c" {
            return code
        }
        return ansiC
    }

    /// Which letter a synthetic ⌘ shortcut presses: ⌘V pastes the dictation, ⌘C copies the selection to speak.
    public enum CommandLetter {
        case v, c
    }

    /// The key-down and key-up of a synthetic ⌘`letter` on `keyCode`, NOT posted: the one place the events are built,
    /// so the app posts exactly what the tests read back. Only ⌘ is set (a modifier still held from the hotkey must not
    /// turn this into ⌃⌘V). The Unicode string is left as the system fills it: an explicit "v"/"c" made Chromium's
    /// web content drop the keystroke (#637), and no app or test is known to match key equivalents on it. The cost:
    /// under "Dvorak – QWERTY ⌘" the string is the plain table's character for the chosen key ("k" on the QWERTY V
    /// position), not the letter the key types with ⌘. nil when the system refuses to make an event.
    public static func commandEvents(_ letter: CommandLetter, keyCode: CGKeyCode,
                                     source: CGEventSource?) -> (down: CGEvent, up: CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
        }
        return (down, up)
    }
}
