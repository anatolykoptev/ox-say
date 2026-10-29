import Foundation

/// One speak-selection press at a time. The capture pumps the main run loop
/// (the ⌘C wait, the Chromium wake), so a second hotkey press is delivered
/// inside the first; it must be ignored, or it would see the attribute the
/// first set, fall to ⌘C over an iPhone copy and speak twice.
public final class CaptureGate {
    private var busy = false

    public init() {}

    /// True when the press may start; false while another is in flight.
    public func begin() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    /// The in-flight press is done. Harmless when none is.
    public func end() { busy = false }
}
