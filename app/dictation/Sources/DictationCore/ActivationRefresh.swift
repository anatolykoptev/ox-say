import Foundation

/// Whether the app becoming active again re-reads what the main window shows. System Settings is another app: a
/// permission granted there changes nothing in the window until something reads it again.
public enum ActivationRefresh {
    /// A permission read this recent already saw what the user did before returning: reading again is the same
    /// event seen twice (opening the window activates the app; coming back from Settings also un-occludes it).
    public static let minimumGap: TimeInterval = 1

    /// `now` and `lastPermissionRead` are readings of the same monotonic clock. The gap measures the age of the
    /// permission read, not of the pass: a pass that began long before may have read the permissions earlier than
    /// the toggle. A read that claims to be in the future (a clock mix-up) is not trusted: refresh.
    public static func shouldRefresh(windowOpen: Bool, visible: Bool, now: TimeInterval,
                                     lastPermissionRead: TimeInterval?) -> Bool {
        guard windowOpen && visible else { return false }
        guard let lastPermissionRead else { return true }
        let age = now - lastPermissionRead
        return age < 0 || age >= minimumGap
    }
}
