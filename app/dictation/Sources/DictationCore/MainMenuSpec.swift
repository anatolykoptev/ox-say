/// The main menu (the menu bar) the app installs, as plain values: titles are
/// L10nKey rows AppKit localizes, actions say what a row fires. Pure, so a
/// dropped item fails a test instead of shipping silently.
///
/// The Edit menu is what makes ⌘Z/⌘X/⌘C/⌘V/⌘A reach a text field: key
/// equivalents are matched against NSApp.mainMenu before they reach the
/// responder chain, and a menu-bar (LSUIElement) app has no main menu at all
/// unless it installs one.

/// What a main-menu row fires. A row aimed at our own code is a typed case —
/// the AppKit layer binds it to a #selector in one exhaustive switch, so the
/// compiler checks the mapping. A row aimed at AppKit names a standard
/// selector, checked by the tests against StandardMenuSelector. A row is one
/// or the other, never both and never neither.
public enum MainMenuAction: Equatable {
    /// A standard AppKit selector ("paste:"), answered by the responder chain
    /// or NSApp; the name must be one of StandardMenuSelector.names.
    case standard(String)
    /// "About OxSay" — the app's own panel; the delegate knows the service
    /// version.
    case about
}

/// The standard AppKit selectors a menu row may name: the ones AppKit itself
/// answers — on NSApplication, the focused window, or through the responder
/// chain. A spec name outside this list fails the spec tests.
public enum StandardMenuSelector {
    public static let names: Set<String> = [
        // Editing, answered through the responder chain.
        "undo:", "redo:", "cut:", "copy:", "paste:", "pasteAsPlainText:",
        "pasteAndMatchStyle:", "delete:", "selectAll:", "startSpeaking:", "stopSpeaking:",
        // Application, answered by NSApplication.
        "hide:", "unhide:", "hideOtherApplications:", "unhideAllApplications:",
        "terminate:", "arrangeInFront:", "miniaturizeAll:",
        "orderFrontStandardAboutPanel:", "showHelp:",
        // Window, answered by the focused NSWindow.
        "performClose:", "miniaturize:", "deminiaturize:",
        "performMiniaturize:", "zoom:", "performZoom:", "toggleToolbarShown:",
    ]
}

/// One clickable row of a main-menu menu.
public struct MainMenuItem: Equatable {
    public let title: L10nKey
    public let keyEquivalent: String
    /// ⇧ on the key equivalent: Redo is ⇧⌘Z.
    public let shift: Bool
    /// What the row fires when clicked or key-matched.
    public let action: MainMenuAction

    public init(title: L10nKey, keyEquivalent: String, shift: Bool = false,
                action: MainMenuAction) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.shift = shift
        self.action = action
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

    /// The menus for an activation policy. `.regular` shows the whole bar —
    /// App (About, Hide, Quit ⌘Q), Edit, Window. Under `.accessory` only the
    /// Edit menu is installed: ⌘Z/⌘X/⌘C/⌘V/⌘A still reach a modal's editor
    /// (the review sheet), but ⌘Q, ⌘H and ⌘W stay unbound — nothing on screen
    /// says the app is active, so a key meant for "dismiss this" must not quit.
    public static func menu(for policy: WindowPolicy.Policy) -> [MainMenuSpec] {
        switch policy {
        case .regular: return [app, edit, window]
        case .accessory: return [edit]
        }
    }

    /// App — About routed to the delegate, then Hide ⌘H and Quit ⌘Q.
    private static let app = MainMenuSpec(title: .menuApp, rows: [
        .item(MainMenuItem(title: .menuAppAbout, keyEquivalent: "", action: .about)),
        .separator,
        .item(MainMenuItem(title: .menuAppHide, keyEquivalent: "h", action: .standard("hide:"))),
        .separator,
        .item(MainMenuItem(title: .menuAppQuit, keyEquivalent: "q", action: .standard("terminate:"))),
    ])

    /// Edit — the standard editing selectors, so ⌘Z/⌘X/⌘C/⌘V/⌘A reach the
    /// responder chain in any of the app's windows.
    private static let edit = MainMenuSpec(title: .menuEdit, rows: [
        .item(MainMenuItem(title: .menuEditUndo, keyEquivalent: "z", action: .standard("undo:"))),
        .item(MainMenuItem(title: .menuEditRedo, keyEquivalent: "z", shift: true, action: .standard("redo:"))),
        .separator,
        .item(MainMenuItem(title: .menuEditCut, keyEquivalent: "x", action: .standard("cut:"))),
        .item(MainMenuItem(title: .menuEditCopy, keyEquivalent: "c", action: .standard("copy:"))),
        .item(MainMenuItem(title: .menuEditPaste, keyEquivalent: "v", action: .standard("paste:"))),
        .separator,
        .item(MainMenuItem(title: .menuEditSelectAll, keyEquivalent: "a", action: .standard("selectAll:"))),
    ])

    /// Window — Minimize ⌘M and Close ⌘W, plus AppKit's appended window titles.
    private static let window = MainMenuSpec(title: .menuWindow, rows: [
        .item(MainMenuItem(title: .menuWindowMinimize, keyEquivalent: "m", action: .standard("performMiniaturize:"))),
        .item(MainMenuItem(title: .menuWindowClose, keyEquivalent: "w", action: .standard("performClose:"))),
    ])
}
