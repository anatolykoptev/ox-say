/// The main menu (the menu bar) the app installs while it is `.regular`, as
/// plain values: titles are L10nKey rows AppKit localizes, actions are selector
/// names AppKit turns into Selectors. Pure, so a dropped item fails a test
/// instead of shipping silently.
///
/// The Edit menu is what makes ⌘Z/⌘X/⌘C/⌘V/⌘A reach a text field: key
/// equivalents are matched against NSApp.mainMenu before they reach the
/// responder chain, and a menu-bar (LSUIElement) app has no main menu at all
/// unless it installs one.

/// Who an item's action is delivered to.
public enum MenuTarget: Equatable {
    /// The responder chain: cut:, paste:, terminate:, performClose:, …
    case responderChain
    /// The app delegate, for items that need app state (About's panel shows the
    /// service version).
    case appDelegate
}

/// One clickable row of a main-menu menu.
public struct MainMenuItem: Equatable {
    public let title: L10nKey
    public let keyEquivalent: String
    /// ⇧ on the key equivalent: Redo is ⇧⌘Z.
    public let shift: Bool
    /// The selector name, e.g. "paste:".
    public let selector: String
    public let target: MenuTarget

    public init(title: L10nKey, keyEquivalent: String, shift: Bool = false,
                selector: String, target: MenuTarget = .responderChain) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.shift = shift
        self.selector = selector
        self.target = target
    }
}

public enum MainMenuRow: Equatable {
    case item(MainMenuItem)
    case separator
}

/// One menu of the menu bar: its own title, then its rows.
public struct MainMenuSpec: Equatable {
    public let title: L10nKey
    public let rows: [MainMenuRow]

    public init(title: L10nKey, rows: [MainMenuRow]) {
        self.title = title
        self.rows = rows
    }
}

public enum MainMenu {
    /// App, Edit, Window — the smallest bar that gives ⌘Q/⌘H, the editing keys
    /// and window control. Standard selectors keep macOS behaviours (the
    /// responder chain delivers them to the focused field).
    public static func spec() -> [MainMenuSpec] {
        [
            MainMenuSpec(title: .menuApp, rows: [
                .item(MainMenuItem(title: .menuAppAbout, keyEquivalent: "",
                                   selector: "showAbout:", target: .appDelegate)),
                .separator,
                .item(MainMenuItem(title: .menuAppHide, keyEquivalent: "h", selector: "hide:")),
                .separator,
                .item(MainMenuItem(title: .menuAppQuit, keyEquivalent: "q", selector: "terminate:")),
            ]),
            MainMenuSpec(title: .menuEdit, rows: [
                .item(MainMenuItem(title: .menuEditUndo, keyEquivalent: "z", selector: "undo:")),
                .item(MainMenuItem(title: .menuEditRedo, keyEquivalent: "z", shift: true, selector: "redo:")),
                .separator,
                .item(MainMenuItem(title: .menuEditCut, keyEquivalent: "x", selector: "cut:")),
                .item(MainMenuItem(title: .menuEditCopy, keyEquivalent: "c", selector: "copy:")),
                .item(MainMenuItem(title: .menuEditPaste, keyEquivalent: "v", selector: "paste:")),
                .separator,
                .item(MainMenuItem(title: .menuEditSelectAll, keyEquivalent: "a", selector: "selectAll:")),
            ]),
            MainMenuSpec(title: .menuWindow, rows: [
                .item(MainMenuItem(title: .menuWindowMinimize, keyEquivalent: "m", selector: "performMiniaturize:")),
                .item(MainMenuItem(title: .menuWindowClose, keyEquivalent: "w", selector: "performClose:")),
            ]),
        ]
    }
}
