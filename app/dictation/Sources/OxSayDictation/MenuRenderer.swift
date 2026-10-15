import AppKit
import DictationCore

/// Draws the pure row models of DictationCore.MenuSections into an NSMenu. No
/// decisions live here: what the rows are, and which are checked or greyed out,
/// is decided by MenuSections and the shortcut plans.
enum MenuRenderer {
    /// What a row's click calls: the selector and the object it carries.
    typealias Binding = (action: Selector, represented: Any)

    /// Replaces the menu's items with `rows`; `bind` maps an action onto the app's selector.
    static func fill(_ menu: NSMenu, rows: [MenuRow], target: AnyObject, bind: (MenuAction) -> Binding) {
        menu.removeAllItems()
        for row in rows {
            switch row {
            case .separator:
                menu.addItem(.separator())
            case .header(let title):
                menu.addItem(header(title))
            case .item(let title, let isOn, let isEnabled, let action):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let action {
                    let binding = bind(action)
                    item.action = binding.action
                    item.target = target
                    item.representedObject = binding.represented
                }
                item.state = isOn ? .on : .off
                item.isEnabled = isEnabled && action != nil
                menu.addItem(item)
            }
        }
    }

    /// A section header: the system's own on macOS 14+, a small grey disabled row on 13.
    static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }
}
