import Foundation

/// Repairing this app's own Accessibility grant from inside the app.
///
/// TCC stores a code requirement with every grant: an entry recorded for an
/// ad-hoc build's cdhash (each source build gets a new one) or for a
/// differently-signed release never matches the running build again, and
/// toggling the switch in System Settings does not rewrite the stored
/// requirement — the entry looks on and does nothing. The only way out is a
/// fresh entry: `tccutil reset Accessibility <bundle id>` drops the stale one
/// so the next trust prompt can store a grant that matches the running build.
///
/// Resetting is safe only because it is scoped to this app's own
/// Accessibility entry — never another bundle's, never a wider service — and
/// it is only offered while that entry does not work.
public enum AccessibilityRepair {
    /// Whether the menu offers the repair: only while pasting cannot work.
    /// Recomputed on every menu open, so the item disappears once the
    /// permission applies.
    public static func shouldOffer(accessibilityTrusted: Bool) -> Bool {
        !accessibilityTrusted
    }

    /// `/usr/bin/tccutil`'s argument vector for resetting this app's own
    /// Accessibility entry. nil when `bundleID` is absent, empty or
    /// whitespace: without a bundle id there is nothing safe to reset, and
    /// callers must not guess.
    public static func resetArguments(bundleID: String?) -> [String]? {
        guard let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ["reset", "Accessibility", bundleID]
    }
}
