import Foundation

/// Browser tab reads off the main thread. An Apple Events read of a browser's
/// front tab can block for 1.5 s (a hung browser, an Automation prompt nobody
/// answered); the 2 s poll must never wait for it. The poll asks for a read —
/// which starts only if none is pending for that browser — and consults the last
/// completed result instead, so a hung browser costs one stuck worker, never a
/// growing queue and never the main thread.
public final class BrowserTabReads {
    private struct Entry {
        var result: BrowserTabURL.Result
        var at: Date
    }

    private let queue: DispatchQueue
    private let now: () -> Date
    private let maxAge: TimeInterval
    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var stored: [String: Entry] = [:]

    /// `maxAge`: how long a completed result still stands for the front tab.
    public init(maxAge: TimeInterval = 10, queue: DispatchQueue, now: @escaping () -> Date = Date.init) {
        self.queue = queue
        self.now = now
        self.maxAge = maxAge
    }

    /// Runs `read` on the queue unless a read for `id` is still pending. Returns
    /// whether it started one.
    @discardableResult
    public func request(_ id: String, read: @escaping () -> BrowserTabURL.Result) -> Bool {
        lock.lock()
        let started = inFlight.insert(id).inserted
        lock.unlock()
        guard started else { return false }
        queue.async { [self] in
            let result = read()
            let finished = now()
            lock.lock()
            stored[id] = Entry(result: result, at: finished)
            inFlight.remove(id)
            lock.unlock()
        }
        return true
    }

    /// The last completed read of `id`, or nil when none completed or it is older
    /// than `maxAge`.
    public func latest(_ id: String) -> BrowserTabURL.Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = stored[id], now().timeIntervalSince(entry.at) <= maxAge else { return nil }
        return entry.result
    }

    /// Forget every result (the watcher stopped); a read still pending finishes into
    /// an empty store and ages out like any other.
    public func reset() {
        lock.lock()
        stored = [:]
        lock.unlock()
    }
}
