import AppKit

/// The menu-bar icon's image. The menu bar draws a template image in its own black or white and ignores
/// `contentTintColor` for it, so a "red" icon set by tint reads black on the bar (#519). A recording icon is therefore a
/// non-template image with the red painted in; the idle icon stays a template, which the bar colours for light and
/// dark itself.
public enum StatusIconImage {
    /// `base` with the small update dot at its top-right corner. One composition for every icon state: a red recording
    /// image keeps its red (non-template), an idle one stays a template the bar colours itself.
    public static func badged(_ base: NSImage, red: Bool, description: String) -> NSImage {
        let badged = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            (red ? NSColor.systemRed : NSColor.black).setFill()
            let dot: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)).fill()
            return true
        }
        badged.isTemplate = !red
        badged.accessibilityDescription = description
        return badged
    }

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
