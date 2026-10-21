/// The "Recent Dictations" submenu as plain rows. AppKit only draws them: the
/// click on row `i` copies `DictationHistory.texts[i]` to the clipboard.
public enum RecentDictationsMenu {
    /// One row per dictation, newest first. Empty history: no rows, and the
    /// submenu's own item is greyed out (`isEnabled`).
    public static func rows(history: DictationHistory) -> [MenuRow] {
        history.titles.enumerated().map { index, title in
            .item(title: title, isOn: false, isEnabled: true, action: .copyDictation(index))
        }
    }

    /// Whether "Recent Dictations" and "Paste Last Dictation" can be chosen.
    public static func isEnabled(history: DictationHistory) -> Bool { !history.isEmpty }
}
