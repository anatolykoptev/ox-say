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
    /// script (`$1` pid, `$2` path, `$3` open, `$4` seconds, `$5` logger), never
    /// interpolated into it. `open` and `logger` are injectable for tests. The
    /// waiter's streams go to /dev/null, so each failure leaves one line in the
    /// unified log: a pid still alive after `timeout` seconds (exit 1, nothing
    /// opened) or an `open` that answered non-zero (its status is the waiter's).
    public static func openAfterExit(pid: Int32, bundlePath: String, open: String = "/usr/bin/open",
                                     timeout: Int = exitTimeout, logger: String = "/usr/bin/logger") -> [String] {
        let script = #"""
        n=0
        while kill -0 "$1" 2>/dev/null; do
            n=$((n + 1))
            if [ "$n" -ge $(($4 * 5)) ]; then
                "$5" -t ox-say-dictation "open-after-exit: pid $1 still alive after $4 s; the new copy opens at next launch"
                exit 1
            fi
            sleep 0.2
        done
        "$3" "$2"
        s=$?
        if [ "$s" -ne 0 ]; then
            "$5" -t ox-say-dictation "open-after-exit: open exited $s"
        fi
        exit "$s"
        """#
        return ["/bin/sh", "-c", script, "sh", String(pid), bundlePath, open, String(timeout), logger]
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
