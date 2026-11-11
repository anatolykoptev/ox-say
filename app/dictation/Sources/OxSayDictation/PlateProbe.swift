import AppKit
import DictationCore

/// The window server's answer about one of the app's always-on-top panels, shared by the dictation pill and the
/// meeting plate. `onscreen` is false for a window that is not on the Space the user is looking at.
enum PlateProbe {
    /// The panel's window as the window server sees it: onscreen and alpha. (false, 0) when the panel has no window
    /// yet or the list knows none.
    static func state(_ panel: NSPanel) -> (onscreen: Bool, alpha: Double) {
        guard panel.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]],
              let entry = list.first else {
            return (false, 0)
        }
        return ((entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0)
    }

    /// False while the screen is locked or the display sleeps: a panel cannot be onscreen then, and that is not a fault.
    static func expectsOnscreen(_ panel: NSPanel) -> Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let display = (panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return PillVisibility.expectsOnscreen(screenLocked: locked, displayAsleep: CGDisplayIsAsleep(display) != 0)
    }

    static func policy() -> WindowPolicy.Policy { NSApp.activationPolicy() == .regular ? .regular : .accessory }
}
