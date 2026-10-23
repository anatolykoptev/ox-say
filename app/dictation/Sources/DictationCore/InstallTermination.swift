import Foundation

/// When an update install may end the app. An install the app starts runs
/// with `UpdateInstaller.appRelaunchesVariable`, so install-app.sh leaves the
/// running copy alone; the app's own `relaunch()` ends it after the install,
/// and that may not land on a dictation that records or transcribes — its text
/// exists nowhere else yet.
public enum InstallTermination {
    /// `relaunch` waits up to this long for a dictation to be idle (a toggle-mode
    /// recording can be long). After it the dictation is still live and the
    /// relaunch goes ahead over it, logged at error level: an install must
    /// finish, a stuck dictation must not hold it for good.
    public static let idleTimeout: TimeInterval = 600
    /// How often the dictation state is looked at while waiting.
    public static let pollInterval: TimeInterval = 0.5

    /// The longest the detached waiter waits for the old process to exit before
    /// it gives up without opening anything (the new bundle then starts at the
    /// next launch).
    public static let exitTimeout = 30

    /// The argv of a detached waiter: it waits for process `pid` to exit, then
    /// opens the bundle at `bundlePath` with plain `open` (not `-n`). The old
    /// app holds the exclusive dictation hotkey until it is gone, so the new copy
    /// must not start before. Everything is passed as argv entries after the
    /// script (`$1` pid, `$2` path, `$3` open, `$4` seconds), never interpolated
    /// into it. `open` is injectable for tests. Exits 1 without opening when
    /// the pid is still alive after `timeout` seconds.
    public static func openAfterExit(pid: Int32, bundlePath: String, open: String = "/usr/bin/open",
                                     timeout: Int = exitTimeout) -> [String] {
        let script = #"""
        n=0
        while kill -0 "$1" 2>/dev/null; do
            n=$((n + 1))
            [ "$n" -ge $(($4 * 5)) ] && exit 1
            sleep 0.2
        done
        exec "$3" "$2"
        """#
        return ["/bin/sh", "-c", script, "sh", String(pid), bundlePath, open, String(timeout)]
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
