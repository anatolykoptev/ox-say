#if canImport(AppKit)
import AppKit
#endif

/// How long an interface animation may run. Under the Mac's Reduce Motion setting every one is a
/// no-op, so the window's animated changes ask here instead of holding their own constant.
public enum MotionPolicy {
    /// 0 under Reduce Motion, `nominal` otherwise.
    public static func animationSeconds(_ nominal: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : nominal
    }

    #if canImport(AppKit)
    /// The Reduce Motion setting for callers that cannot take the SwiftUI environment value.
    public static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    #endif
}
