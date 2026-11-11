import Foundation

/// A signal that may arrive before anyone listens. `fire()` with no handler is held (once, however many fires) and
/// handed over, exactly once, when the handler is assigned; with a handler it is delivered at once. For a notification
/// the system hands to the app at launch, before the code that reacts to it exists.
@MainActor
public final class LatchedSignal {
    private var handler: (() -> Void)?
    private var pending = false

    public init() {}

    public func fire() {
        if let handler { handler() } else { pending = true }
    }

    public func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
        if pending {
            pending = false
            handler()
        }
    }
}
