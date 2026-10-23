import Foundation

/// When an update install may end the app. An install the app starts runs
/// with `UpdateInstaller.appRelaunchesVariable`, so install-app.sh leaves the
/// running copy alone; the app's own `relaunch()` ends it after the install,
/// and that may not land on a dictation that records or transcribes — its text
/// exists nowhere else yet.
public enum InstallTermination {
    /// The longest `relaunch` waits for a dictation before it goes ahead
    /// anyway (and logs it): an install must finish, a stuck dictation must
    /// not hold it for good.
    public static let idleTimeout: TimeInterval = 120
    /// How often the dictation state is looked at while waiting.
    public static let pollInterval: TimeInterval = 0.5

    public enum Wait: Equatable {
        case idle
        /// Still not idle after the timeout.
        case timedOut
    }

    /// Returns once `state` reads idle, or after `timeout`. `sleep` is injected
    /// so the caller's clock is the only real time in the loop.
    public static func waitForIdle(state: () -> DictationState,
                                   timeout: TimeInterval = idleTimeout,
                                   interval: TimeInterval = pollInterval,
                                   sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async -> Wait {
        var waited: TimeInterval = 0
        while state() != .idle {
            if waited >= timeout { return .timedOut }
            await sleep(interval)
            waited += interval
        }
        return .idle
    }
}
