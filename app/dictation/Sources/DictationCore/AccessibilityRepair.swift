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

/// One tccutil reset at a time, off the main thread. The process itself is the
/// caller's: `launch` starts it, calls `onExit` with its status when it ends
/// (on the main queue) and returns a way to terminate it. A reset that does not
/// end within `timeoutSeconds` (a stuck tccd) is terminated, so the exit path
/// runs and the caller hears a failure instead of keeping a greyed row for the
/// session. Tests drive a fake and a hand-made clock; nothing real is reset.
public final class AccessibilityRepairRun {
    public enum Start: Equatable {
        case started
        /// A reset is already running.
        case busy
        /// No usable bundle id — nothing safe to reset.
        case unavailable
        /// The process could not be started.
        case launchFailed
    }

    /// tccutil answers in well under a second; 10 s is far past slow yet short
    /// enough that the user is not left with a dead menu row.
    public static let timeoutSeconds: TimeInterval = 10
    /// How long a process that ignores the termination gets before the run is
    /// freed anyway.
    public static let graceSeconds: TimeInterval = 2

    public private(set) var isRunning = false

    public init() {}

    public func start(bundleID: String?,
                      launch: ([String], @escaping (Int32) -> Void) throws -> () -> Void,
                      schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                          DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                      },
                      completion: @escaping (Bool) -> Void) -> Start {
        guard !isRunning else { return .busy }
        guard let arguments = AccessibilityRepair.resetArguments(bundleID: bundleID) else { return .unavailable }
        isRunning = true
        // Per-run state: a timeout of an earlier run finds its own `done` set.
        let state = RunState()
        let finish: (Bool) -> Void = { [weak self] ok in
            guard !state.done else { return }
            state.done = true
            self?.isRunning = false
            completion(ok)
        }
        let terminate: () -> Void
        do {
            terminate = try launch(arguments) { status in finish(status == 0) }
        } catch {
            isRunning = false
            return .launchFailed
        }
        schedule(Self.timeoutSeconds) {
            guard !state.done else { return }
            terminate()
            // The termination normally reports through onExit; a process that
            // ignores it must not hold the run for good.
            schedule(Self.graceSeconds) { finish(false) }
        }
        return .started
    }

    private final class RunState { var done = false }
}
