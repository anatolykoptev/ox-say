import Foundation

/// Whether the app becoming active again re-reads what the main window shows. System Settings is another app: a
/// permission granted there changes nothing in the window until something reads it again.
public enum ActivationRefresh {
    /// Activation that follows another refresh pass this closely is the same event seen twice (opening the window
    /// activates the app; coming back from System Settings also un-occludes the window): that pass is enough.
    public static let minimumGap: TimeInterval = 1

    public static func shouldRefresh(windowOpen: Bool, visible: Bool, secondsSinceLastPass: TimeInterval? = nil) -> Bool {
        guard windowOpen && visible else { return false }
        guard let age = secondsSinceLastPass else { return true }
        return age >= minimumGap
    }
}
