import AppKit
import DictationCore

/// Draws DictationCore's MainMenuSpec.menu(for:) into NSApp.mainMenu. No
/// decisions live here: which menus exist for a policy, what the rows say and
/// which keys they carry is all in the spec.
enum MainMenuBar {
    /// Installs the menu for `policy`. `appDelegate` is the explicit target of
    /// the typed actions (About); standard selectors ride the responder chain.
    static func install(appDelegateTarget appDelegate: AppDelegate, for policy: WindowPolicy.Policy) {
        let bar = NSMenu()
        NSApp.windowsMenu = nil
        for spec in MainMenuSpec.menu(for: policy) {
            let item = NSMenuItem(title: spec.title.text, action: nil, keyEquivalent: "")
            let rendered = submenu(spec, appDelegate: appDelegate)
            item.submenu = rendered
            bar.addItem(item)
            // The Window menu joins window management (appended window titles).
            if spec.title == .menuWindow { NSApp.windowsMenu = rendered }
        }
        NSApp.mainMenu = bar
    }

    private static func submenu(_ spec: MainMenuSpec, appDelegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: spec.title.text)
        for row in spec.rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let rendered = NSMenuItem(title: item.title.text, action: nil,
                                          keyEquivalent: item.keyEquivalent)
                if item.shift { rendered.keyEquivalentModifierMask = [.command, .shift] }
                bind(item.action, to: rendered, appDelegate: appDelegate)
                menu.addItem(rendered)
            }
        }
        return menu
    }

    /// The one place a row's action meets its implementation. A typed action
    /// is resolved by an exhaustive switch — the compiler checks the mapping —
    /// and aimed at the delegate; a standard selector stays a name and rides
    /// the responder chain (target nil).
    private static func bind(_ action: MainMenuAction, to item: NSMenuItem, appDelegate: AppDelegate) {
        switch action {
        case .standard(let name):
            item.action = NSSelectorFromString(name)
        case .about:
            item.action = #selector(AppDelegate.showAbout)
            item.target = appDelegate
        }
    }
}
