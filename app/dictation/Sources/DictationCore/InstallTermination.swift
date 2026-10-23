import Foundation

/// When an update install may end the app. The installer ends it twice over:
/// install-app.sh SIGTERMs the running copy, and `relaunch()` ends it after a
/// successful install. Neither may land on a dictation that records or
/// transcribes — its text exists nowhere else yet.
public enum InstallTermination {
    /// The longest `relaunch` waits for a dictation before it goes ahead
    /// anyway (and logs it): an install must finish, a stuck dictation must
    /// not hold it for good.
    public static let idleTimeout: TimeInterval = 120
    /// How often the dictation state is looked at while waiting.
    public static let pollInterval: TimeInterval = 0.5

    /// What a SIGTERM does to the app.
    public enum Sigterm: Equatable {
        /// End now (a plain `kill`, or an install with nothing dictating).
        case terminate
        /// An install is running and a dictation with it: keep going, the
        /// install's own `relaunch()` ends the app once the dictation is idle.
        case leaveToRelaunch
    }

    public static func sigterm(installing: Bool, dictation: DictationState) -> Sigterm {
        installing && dictation != .idle ? .leaveToRelaunch : .terminate
    }

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
