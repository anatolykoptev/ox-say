import AppKit
import DictationCore

/// Draws DictationCore's MainMenu.spec() into NSApp.mainMenu. No decisions
/// live here: which menus exist, what the rows say and which keys they carry
/// is all in the spec.
enum MainMenuBar {
    /// `appDelegateTarget` receives the actions marked .appDelegate (About).
    static func install(appDelegateTarget: AnyObject) {
        let bar = NSMenu()
        for spec in MainMenu.spec() {
            let item = NSMenuItem(title: spec.title.text, action: nil, keyEquivalent: "")
            let rendered = submenu(spec, appDelegateTarget: appDelegateTarget)
            item.submenu = rendered
            bar.addItem(item)
            // The Window menu joins window management (appended window titles).
            if spec.title == .menuWindow { NSApp.windowsMenu = rendered }
        }
        NSApp.mainMenu = bar
    }

    private static func submenu(_ spec: MainMenuSpec, appDelegateTarget: AnyObject) -> NSMenu {
        let menu = NSMenu(title: spec.title.text)
        for row in spec.rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let rendered = NSMenuItem(title: item.title.text,
                                          action: NSSelectorFromString(item.selector),
                                          keyEquivalent: item.keyEquivalent)
                if item.shift { rendered.keyEquivalentModifierMask = [.command, .shift] }
                if item.target == .appDelegate { rendered.target = appDelegateTarget }
                menu.addItem(rendered)
            }
        }
        return menu
    }
}
