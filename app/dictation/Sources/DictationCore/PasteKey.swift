/// ⌘V must press the key that types "v" in the current layout, not the QWERTY
/// position: on Dvorak the QWERTY V key is "k", and the letter v sits on the
/// QWERTY "." key. Non-Latin layouts such as Russian have no "v" at all, but
/// macOS resolves ⌘ shortcuts through the ASCII-capable layout, so the QWERTY
/// key is still right there.
public enum PasteKey {
    /// kVK_ANSI_V as a plain number: DictationCore does not link Carbon.
    public static let ansiV = 9

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
}
