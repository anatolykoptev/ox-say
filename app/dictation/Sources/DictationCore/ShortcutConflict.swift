/// A macOS system shortcut (System Settings → Keyboard → Keyboard Shortcuts), as
/// Carbon's CopySymbolicHotKeys reports it: a virtual key code and Carbon
/// modifier bits.
public struct SystemShortcut: Equatable {
    public var keyCode: Int
    public var modifiers: Int
    public var enabled: Bool

    public init(keyCode: Int, modifiers: Int, enabled: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.enabled = enabled
    }
}

public enum ShortcutConflict {
    /// ⌘ ⇧ ⌥ ⌃ in Carbon's modifier format; other bits (caps lock, key
    /// flags) do not make a shortcut different.
    static let mask = 0x100 | 0x200 | 0x800 | 0x1000

    /// Whether an enabled system shortcut already uses this key combination.
    /// A Carbon hotkey registers fine on top of one, so this is the only way
    /// to know: ⌃Space, for example, switches input sources on a stock Mac.
    public static func taken(keyCode: Int, modifiers: Int, by system: [SystemShortcut]) -> Bool {
        system.contains { $0.enabled && $0.keyCode == keyCode && $0.modifiers & mask == modifiers & mask }
    }
}
