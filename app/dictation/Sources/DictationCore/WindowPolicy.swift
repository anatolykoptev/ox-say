import Foundation

/// Which app window a description belongs to, for the activation policy.
public enum WindowKind: Equatable {
    /// The main editor window — the only kind that holds a Dock icon.
    case main
    /// The standard about panel.
    case about
    /// The voiceover review sheet.
    case review
    /// The dictation pill: a borderless, non-activating panel.
    case overlay
    /// Any other panel or window.
    case panel
}

/// One window as the policy sees it: what kind it is, whether AppKit lets it
/// become the main window, and whether it is on screen.
public struct WindowDescription: Equatable {
    public let kind: WindowKind
    public let canBecomeMain: Bool
    public let visible: Bool

    public init(kind: WindowKind, canBecomeMain: Bool, visible: Bool) {
        self.kind = kind
        self.canBecomeMain = canBecomeMain
        self.visible = visible
    }
}

/// What the app is, Dock-icon-wise. `.regular` shows the Dock icon and the
/// menu bar; `.accessory` is the menu-bar app it was.
public enum WindowPolicy {
    public enum Policy: Equatable {
        case regular
        case accessory
    }

    /// Seconds between a main-window close and the fall back to `.accessory`:
    /// the closing window needs a moment to leave NSApp.windows, and a quick
    /// close→reopen must not flicker the Dock icon.
    public static let accessoryRevertDelay: TimeInterval = 0.3

    /// `.regular` while a main window is up, `.accessory` otherwise. Only the
    /// main window counts: the about panel, the review sheet and the overlay
    /// pill all lived under `.accessory` before it existed, and each activates
    /// the app itself when it needs focus.
    public static func policy(for windows: [WindowDescription]) -> Policy {
        windows.contains { $0.kind == .main && $0.visible && $0.canBecomeMain } ? .regular : .accessory
    }
}
