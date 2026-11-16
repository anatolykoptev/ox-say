import Foundation

/// What keeps a recording alive when the Mac or the app does not (#531). The audio is appended with `write(2)`, so an
/// app killed with `kill -9` loses nothing that was already written: the kernel owns those bytes. What a power loss, a
/// kernel panic or a forced shutdown takes is whatever the kernel had not yet put on the disk, so the files are synced
/// on a short, fixed cadence, and the Mac is told not to fall asleep on its own while the recording runs. A sleep
/// itself ends the recording (`MeetingController.stopForSleep`, on `willSleepNotification`), so there is no wake path.
public enum RecordingDurability {
    /// The longest a power loss can cost: the channel files are flushed to the disk this often while recording.
    public static let flushInterval: TimeInterval = 2
}

/// Calls `action` every `interval` seconds on `queue` until `stop`. A DispatchSource timer, so the cadence does not
/// depend on a run loop or on the main thread being free.
public final class PeriodicFlush {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let action: () -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    public init(interval: TimeInterval = RecordingDurability.flushInterval,
                queue: DispatchQueue = DispatchQueue(label: "ox-say.recording-flush", qos: .utility),
                action: @escaping () -> Void) {
        self.interval = interval
        self.queue = queue
        self.action = action
    }

    public var isRunning: Bool { lock.withLock { timer != nil } }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(max(1, min(100, Int(interval * 100)))))
            t.setEventHandler { [action] in action() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}

/// Holds a power/App Nap activity from `hold` to `release`, once. `begin` returns the token the system gave and `end`
/// hands it back; both are injected, so the tests count them and the app passes `ProcessInfo.beginActivity`.
public final class ActivityHold {
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    public init(begin: @escaping (String) -> NSObjectProtocol, end: @escaping (NSObjectProtocol) -> Void) {
        self.begin = begin
        self.end = end
    }

    /// The system's own: no idle system sleep and no App Nap throttling of the timers while the recording runs. The
    /// display may still sleep, and closing the lid or choosing Sleep still sleeps the Mac: only idle sleep is held.
    public static var system: ActivityHold {
        ActivityHold(begin: { ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: $0) },
                     end: { ProcessInfo.processInfo.endActivity($0) })
    }

    public var isHeld: Bool { lock.withLock { token != nil } }

    public func hold(reason: String) {
        lock.withLock { if token == nil { token = begin(reason) } }
    }

    public func release() {
        lock.withLock {
            if let t = token { end(t); token = nil }
        }
    }
}
