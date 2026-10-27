import Foundation

public enum ScriptOutcome: Equatable {
    case value(String)
    /// -1743: Automation is not allowed for this player.
    case denied
    case timedOut
    case failed(Int)
}

/// Runs AppleScript source with a hard deadline for the caller.
public protocol AppleScriptRunner {
    func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome
}

/// Scripts on their own serial queue. The caller waits at most `timeout`; the
/// script itself is bounded by `with timeout of 1 second`, so a hung player
/// blocks the worker for about a second, not the 2-minute default. One runner
/// per player, so a hung Music never queues Spotify's calls behind it.
/// `execute` is NSAppleScript in the app and a stand-in in tests.
///
/// `dropWhileBusy` is for a poller (the call watcher's tab read): while an earlier script is still running on the
/// worker — an Automation prompt nobody answered holds it far past its own `with timeout` — a new one is not queued
/// behind it, it is dropped and answered `.timedOut`. Without it every poll adds a script that runs, one after the
/// other, once the prompt clears (#251). A command that must reach its target (a media player's `play`) leaves it off.
public final class QueuedScriptRunner: AppleScriptRunner {
    private final class Slot { var outcome: ScriptOutcome = .failed(0) }

    private let worker: DispatchQueue
    private let execute: (String) -> ScriptOutcome
    private let dropWhileBusy: Bool
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0

    public init(label: String = "", dropWhileBusy: Bool = false,
                execute: @escaping (String) -> ScriptOutcome = QueuedScriptRunner.executeWithNSAppleScript) {
        worker = DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.applescript\(label.isEmpty ? "" : "." + label)")
        self.execute = execute
        self.dropWhileBusy = dropWhileBusy
    }

    /// A script is queued or running on the worker.
    public var isBusy: Bool { lock.withLock { pending > 0 } }

    /// Scripts a `dropWhileBusy` runner refused because the worker was occupied.
    public var droppedWhileBusy: Int { lock.withLock { dropped } }

    public func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome {
        let admitted: Bool = lock.withLock {
            if dropWhileBusy, pending > 0 {
                dropped += 1
                return false
            }
            pending += 1
            return true
        }
        guard admitted else { return .timedOut }
        let slot = Slot()
        let done = DispatchSemaphore(value: 0)
        worker.async { [execute, self] in
            slot.outcome = execute(source)
            lock.withLock { pending -= 1 }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        return slot.outcome
    }

    /// -1743 is errAEEventNotPermitted: Automation was denied for the target.
    public static func outcome(errorNumber: Int) -> ScriptOutcome {
        errorNumber == -1743 ? .denied : .failed(errorNumber)
    }

    public static func executeWithNSAppleScript(_ source: String) -> ScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .failed(0) }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info { return outcome(errorNumber: (info["NSAppleScriptErrorNumber"] as? Int) ?? 0) }
        return .value(result.stringValue ?? "")
    }
}

/// Music or Spotify driven through AppleScript. Its two safeguards against
/// launching a player the user did not start: the running check below, and the
/// same check inside every script (`tell application` would launch it).
public final class ScriptedMediaPlayer: MediaPlayer {
    public static let musicBundleID = "com.apple.Music"
    public static let spotifyBundleID = "com.spotify.client"
    /// What `MediaWait.quick` waits: a player slower than this is skipped.
    public static let callTimeout: TimeInterval = 0.3
    /// What `MediaWait.confirming` waits: longer than the script's own
    /// `with timeout of 1 second`, so a slow call is outwaited, not abandoned.
    public static let confirmTimeout: TimeInterval = 1.5

    private let bundleID: String
    private let isRunning: (String) -> Bool
    private let runner: AppleScriptRunner
    private let log: (String) -> Void

    public var identifier: String { bundleID }

    /// `isRunning` answers from the system's process list for a bundle id (no
    /// Apple Event); `log` receives one line without user content.
    public init(bundleID: String, isRunning: @escaping (String) -> Bool,
                runner: AppleScriptRunner, log: @escaping (String) -> Void = { _ in }) {
        self.bundleID = bundleID
        self.isRunning = isRunning
        self.runner = runner
        self.log = log
    }

    public func state(wait: MediaWait) -> MediaPlaybackState {
        guard isRunning(bundleID) else { return .notRunning }
        let timeout = wait == .quick ? Self.callTimeout : Self.confirmTimeout
        switch run(Self.script(bundleID, body: "return player state as text"), op: "state", timeout: timeout) {
        case .value("playing"): return .playing
        case .value("paused"): return .paused
        case .value("stopped"): return .stopped
        case .value("notRunning"): return .notRunning
        case .denied: return .denied
        case .timedOut: return .timedOut
        default: return .unavailable
        }
    }

    public func pause() { _ = command("pause", timeout: Self.callTimeout) }

    /// Only ever the giving-back call, so it is outwaited like `.confirming`.
    /// Its outcome is the coordinator's signal: a non-value means the player
    /// may still be paused.
    @discardableResult
    public func play() -> ScriptOutcome { command("play", timeout: Self.confirmTimeout) }

    /// A player that is already gone needs no command — and gets none: the
    /// running check is what keeps a `tell` from launching it.
    private func command(_ verb: String, timeout: TimeInterval) -> ScriptOutcome {
        guard isRunning(bundleID) else { return .value("notRunning") }
        return run(Self.script(bundleID, body: "\(verb)\nreturn \"ok\""), op: verb, timeout: timeout)
    }

    private func run(_ source: String, op: String, timeout: TimeInterval) -> ScriptOutcome {
        let outcome = runner.run(source, timeout: timeout)
        switch outcome {
        case .value: break
        case .denied: log("\(bundleID) \(op): automation denied (-1743)")
        case .timedOut: log("\(bundleID) \(op): timed out")
        case .failed(let code): log("\(bundleID) \(op): failed code=\(code)")
        }
        return outcome
    }

    /// The `is running` test does not launch the app; the `tell` inside it is
    /// reached only when the app is up. `bundleID` is one of the constants above.
    static func script(_ bundleID: String, body: String) -> String {
        """
        if application id "\(bundleID)" is running then
            with timeout of 1 second
                tell application id "\(bundleID)"
                    \(body)
                end tell
            end timeout
        end if
        return "notRunning"
        """
    }
}
