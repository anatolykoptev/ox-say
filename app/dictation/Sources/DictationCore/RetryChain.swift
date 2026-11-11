import Foundation

/// The retry chain of one restartable source (the microphone after a route change): try now, and on a failure again
/// after `Reacquire`'s delays for as long as the recording runs.
///
/// A chain belongs to ONE recording (#266). Every timer remembers the generation it was scheduled in; `begin` (a new
/// recording), `cancel` (the recording ended) and `run` (a new route change supersedes a chain that is still waiting)
/// move the generation on, so a timer left over from an earlier chain finds itself stale and does nothing, instead of
/// restarting the source next to the new recording. Not thread-safe: call it from one thread (the main thread).
public final class RetryChain {
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let attempt: () throws -> Void
    private let schedule: Schedule
    private let onFailed: (Error) -> Void
    private let onRecovered: () -> Void
    private var generation = 0
    private var reacquire = Reacquire()

    /// `attempt` starts the source and throws when it could not; `schedule` runs a closure after a delay (the main
    /// queue in the app, a fake in tests). `onFailed` hears the error that began a streak (the app logs it and says a sentence of its own), `onRecovered` the success
    /// that ends one.
    public init(attempt: @escaping () throws -> Void, schedule: @escaping Schedule,
                onFailed: @escaping (Error) -> Void, onRecovered: @escaping () -> Void) {
        self.attempt = attempt
        self.schedule = schedule
        self.onFailed = onFailed
        self.onRecovered = onRecovered
    }

    /// A recording begins: nothing from an earlier one may act, and its failures are forgotten.
    public func begin() {
        generation += 1
        reacquire = Reacquire()
    }

    /// The recording ended: a pending timer must not fire into whatever comes next.
    public func cancel() {
        generation += 1
    }

    /// Try now (a route change). Supersedes a chain that is still waiting for its next step.
    public func run() {
        generation += 1
        step(generation)
    }

    private func step(_ mine: Int) {
        do {
            try attempt()
            if reacquire.succeeded() { onRecovered() }
        } catch {
            let next = reacquire.failed()
            if next.notify { onFailed(error) }
            schedule(next.delay) { [weak self] in
                guard let self, self.generation == mine else { return }
                self.step(mine)
            }
        }
    }
}

/// An empty meeting left behind by a start that never began recording (#270): the daemon opened it, the recorder could
/// not start. It is finished (the daemon refuses to delete a recording one) and deleted; 404 counts as gone.
public enum EmptyMeetingCleanup {
    public enum Outcome: Equatable {
        case deleted
        /// The daemon no longer has it.
        case gone
        /// Still there. `why` says so with the daemon's status only: safe for the public log. `detail` holds the
        /// daemon's own words, for the private log. Neither is ever shown: the user already got the start failure.
        case left(why: String, detail: String)
    }

    /// A finished meeting is queued for a moment, and the daemon refuses to delete one it is working on (409).
    public static let waits: [TimeInterval] = [0.5, 1, 2, 4]

    public static func discard(finish: () async throws -> Void, delete: () async throws -> Void,
                               sleep: (TimeInterval) async -> Void) async -> Outcome {
        var finishFailure: String?
        var details: [String] = []
        do { try await finish() } catch {
            if isNotFound(error) { return .gone }
            finishFailure = "finish: \(LogDetail.publicText(error))"
            details.append(LogDetail.privateText(error))
        }
        var last = ""
        var lastDetail = ""
        for attempt in 0...waits.count {
            do {
                try await delete()
                return .deleted
            } catch {
                if isNotFound(error) { return .gone }
                last = "delete: \(LogDetail.publicText(error))"
                lastDetail = LogDetail.privateText(error)
                guard case StudioError.refused(let status, _) = error, status == 409 else { break }
                if attempt < waits.count { await sleep(waits[attempt]) }
            }
        }
        return .left(why: [finishFailure, last].compactMap { $0 }.joined(separator: "; "),
                     detail: (details + [lastDetail]).filter { !$0.isEmpty }.joined(separator: "; "))
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case StudioError.refused(let status, _) = error { return status == 404 }
        return false
    }
}

/// A rename leaves the notes-folder copy stale; the meeting is read again to copy it. That read is retried (the daemon
/// may be busy) but never on the path the window's refresh waits for (#270): the caller starts it as its own task.
public enum StaleCopyRefresh {
    /// Waits after the 1st and the 2nd failed read; there is no wait after the last one.
    public static let waits: [TimeInterval] = [1, 2]
    public static var worstCaseDelay: TimeInterval { waits.reduce(0, +) }

    public static func run<T>(read: () async -> T?, sleep: (TimeInterval) async -> Void) async -> T? {
        for index in 0...waits.count {
            if let value = await read() { return value }
            if index < waits.count { await sleep(waits[index]) }
        }
        return nil
    }
}

/// Where the recording badge sits. It is centred when it appears; a later change of its width (the consent button
/// hides) keeps its left edge, so the buttons do not move under the pointer (#251).
public enum BadgePlacement {
    public static func originX(anchoredLeft: Double?, width: Double, screenMidX: Double) -> Double {
        anchoredLeft ?? screenMidX - width / 2
    }

    /// One display's usable area (below the menu bar, beside the Dock) in the global coordinates AppKit uses.
    public struct Screen: Equatable {
        public var id: UInt32
        public var minX: Double
        public var maxX: Double
        public var maxY: Double
        public var minY: Double
        /// What a remembered spot is filed under: the display's UUID. A `CGDirectDisplayID` is not stable across
        /// reconnects, so the id only says which screen is meant NOW.
        public var key: String
        public init(id: UInt32, minX: Double, maxX: Double, maxY: Double, minY: Double = -Double.greatestFiniteMagnitude,
                    key: String? = nil) {
            self.id = id; self.minX = minX; self.maxX = maxX; self.maxY = maxY; self.minY = minY; self.key = key ?? String(id)
        }
        var midX: Double { (minX + maxX) / 2 }
    }

    public struct Placement: Equatable {
        public var screenID: UInt32
        public var x: Double
        public var y: Double
        /// `x` from the screen's left edge: what to keep when the screens move about (a monitor left of this one is
        /// unplugged and every coordinate shift).
        public var offset: Double
        /// The gap between the panel's top and the top of the screen's usable area: what a drag changes vertically.
        public var topInset: Double = BadgePlacement.topMargin
    }

    /// Where the user left the plate on one display: from that display's left edge and down from its top.
    public struct Saved: Equatable {
        public var dx: Double
        public var topInset: Double
        public init(dx: Double, topInset: Double) { self.dx = dx; self.topInset = topInset }
    }

    /// The gap under the top of the screen.
    public static let topMargin: Double = 8

    /// Where the badge goes among the screens that exist now. The screen it already sits on keeps it (`placedOn`); when
    /// that one is gone (unplugged during a prompt) or the badge is new, the main screen takes it, else the first
    /// one; no screens at all (the lid closed, the display asleep) is nil, and the badge stays where it is until the
    /// next change. A badge that stays on its screen keeps its left edge (#251) as a distance from that screen's left
    /// (`anchoredOffset`, from a former `Placement.offset`) and its gap from the top (`anchoredInset`), so a shifted
    /// arrangement does not move it; it is moved only as far as the screen's new size needs. A badge that is new on a
    /// screen goes where the user last left it there (`saved`, by display id), else it is centred. The result always
    /// lies inside its screen.
    public static func place(screens: [Screen], placedOn: UInt32?, main: UInt32?, anchoredOffset: Double?,
                             anchoredInset: Double? = nil, saved: [String: Saved] = [:],
                             width: Double, height: Double) -> Placement? {
        let kept = placedOn.flatMap { id in screens.first { $0.id == id } }
        guard let screen = kept ?? main.flatMap({ id in screens.first { $0.id == id } }) ?? screens.first else { return nil }
        let remembered = kept == nil ? saved[screen.key] : nil
        let left = kept == nil ? remembered.map { screen.minX + $0.dx } : anchoredOffset.map { screen.minX + $0 }
        let inset = kept == nil ? (remembered?.topInset ?? topMargin) : (anchoredInset ?? topMargin)
        let x = originX(anchoredLeft: left, width: width, screenMidX: screen.midX)
        let room = screen.maxX - screen.minX - width
        let inside = room > 0 ? min(max(x, screen.minX), screen.minX + room) : screen.minX
        let y = max(screen.maxY - height - max(inset, 0), screen.minY)
        return Placement(screenID: screen.id, x: inside, y: y, offset: inside - screen.minX, topInset: screen.maxY - height - y)
    }
}

/// The plate's remembered spots, one per display, in the user defaults.
public enum BadgePositions {
    public static let key = "meeting.badge.positions"

    public static func load(_ d: UserDefaults) -> [String: BadgePlacement.Saved] {
        guard let raw = d.dictionary(forKey: key) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? BadgePlacement.Saved(dx: $0[0], topInset: $0[1]) : nil }
    }

    /// `key`: the display's UUID (`BadgePlacement.Screen.key`). Spots filed under the old numeric ids are never matched
    /// and so are dropped by use: the plate is centred once per display and remembered again.
    public static func save(key display: String, dx: Double, topInset: Double, _ d: UserDefaults) {
        var raw = (d.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        raw[display] = [dx, topInset]
        d.set(raw, forKey: key)
    }
}
