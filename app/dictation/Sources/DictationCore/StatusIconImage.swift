import AppKit

/// The menu-bar icon's image. The menu bar draws a template image in its own black or white and ignores
/// `contentTintColor` for it, so a "red" icon set by tint reads black on the bar (#519). A recording icon is therefore a
/// non-template image with the red painted in; the idle icon stays a template, which the bar colours for light and
/// dark itself.
public enum StatusIconImage {
    public static func make(symbol: String, red: Bool, description: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return nil }
        guard red else {
            base.isTemplate = true
            return base
        }
        let painted = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? base
        painted.isTemplate = false
        return painted
    }
}
