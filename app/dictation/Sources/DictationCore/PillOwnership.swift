import Foundation

/// Whether a task that put a pill up may still take it down. The overlay counts
/// the owners that took it — every show bumps the count — and a task keeps the
/// count it saw right after its show. Its finish is allowed only while that
/// count still stands (nobody since took the pill: a dictation, a message, a
/// speak) and no dictation is running: a completion landing mid-recording must
/// never take the dictation's pill away.
public enum PillOwnership {
    /// Live text belongs to the dictation that produced it. A streaming reply can land after the dictation ended, or
    /// after another owner (a message, the install or playback pill) took the pill: it is dropped, so it never
    /// reaches a pill that is not the dictation's.
    public static func acceptsLiveText(dictation: DictationState) -> Bool {
        dictation != .idle
    }

    /// The playback look (pause, position, stop) replaces the pill's current look, so it is shown only where no
    /// dictation runs: a recording keeps its own.
    public static func mayShowPlayback(dictation: DictationState) -> Bool {
        dictation == .idle
    }

    /// `owner` is the overlay's owner count captured right after the task's
    /// show (nil when the task never showed one); `current` is that count now;
    /// `dictation` is the controller's state.
    public static func shouldFinish(owner: Int?, current: Int, dictation: DictationState) -> Bool {
        guard let owner, owner == current else { return false }
        return dictation == .idle
    }
}

/// How the dictation looks on the pill: the look a refused finish or a hide
/// landing mid-dictation puts back.
public enum PillDictationLook: Equatable {
    case listening
    case working

    /// nil while no dictation runs.
    public init?(dictation: DictationState) {
        switch dictation {
        case .idle: return nil
        case .recording: self = .listening
        case .transcribing: self = .working
        }
    }
}

/// One task's claim on the pill: `begin` right after the task's show captures
/// the overlay's owner count, `end` is the only way the task takes it down.
/// Capture and clear live in one value, so a single call site can be gated
/// and the decision is tested without AppKit.
public struct PillSlot: Equatable {
    public enum End: Equatable {
        /// Still ours and nothing dictates: take the pill down.
        case finish
        /// Still ours but a dictation runs: the finish is refused, and the
        /// task's label (Speaking…, Reading…) gives way to the dictation's look.
        case restore(PillDictationLook)
        /// Nothing to do: never begun, spent, or another owner took the pill.
        case leave
    }

    public private(set) var owner: Int?

    public init() {}

    /// The overlay's owner count right after the task's show.
    public mutating func begin(owner: Int) { self.owner = owner }

    /// Whether the pill is still the one this slot began and no dictation runs
    /// (the playback show uses it); the slot is left as it is.
    public func stillOurs(current: Int, dictation: DictationState) -> Bool {
        PillOwnership.shouldFinish(owner: owner, current: current, dictation: dictation)
    }

    /// Spends the slot and says what the pill should do.
    public mutating func end(current: Int, dictation: DictationState) -> End {
        defer { owner = nil }
        guard let owner, owner == current else { return .leave }
        if let look = PillDictationLook(dictation: dictation) { return .restore(look) }
        return .finish
    }
}

/// Whether the window server can be expected to show the pill at all.
public enum PillVisibility {
    public static func expectsOnscreen(screenLocked: Bool, displayAsleep: Bool) -> Bool {
        !screenLocked && !displayAsleep
    }
}

/// The window-server check of the pill is skipped while the screen is locked or the display sleeps; this
/// remembers the show it was skipped for, so one unlock or wake can arm it again.
public struct PillRecheck: Equatable {
    private var pending: Int?

    public init() {}

    /// The check of show `show` was skipped.
    public mutating func skipped(show: Int) { pending = show }

    /// The screen unlocked or the display woke: true when exactly the skipped show is still the one up (`show` is
    /// the overlay's current show count) and wanted. Spent either way, so one skip arms one check.
    public mutating func resume(show: Int, wantsVisible: Bool) -> Bool {
        defer { pending = nil }
        return wantsVisible && pending == show
    }
}

/// How long a pill message stays up.
public enum PillTiming {
    /// How long the pill takes to change width while it is on screen. A growing live text animates; every other resize
    /// snaps, with a zero duration through the same animator, which cuts a grow still in flight short instead of
    /// racing it: a plain `setFrame` beside an animator-driven one leaves the final width to whichever writes last
    /// (#191.5).
    public static let resizeAnimationSeconds: Double = 0.15

    public static func resizeSeconds(animated: Bool) -> Double {
        animated ? resizeAnimationSeconds : 0
    }

    public static let baseMessageSeconds: Double = 4
    public static let maxMessageSeconds: Double = 12
    /// A comfortable reading speed for a short notice.
    private static let charactersPerSecond = 20.0

    /// The base for a short message; longer text adds reading time, capped.
    public static func messageSeconds(characters: Int) -> Double {
        let reading = Double(max(0, characters)) / charactersPerSecond + 1.5
        return min(maxMessageSeconds, max(baseMessageSeconds, reading))
    }
}

/// The pills of the Studio tasks that can run at once (a voice being designed
/// while a document is read): one slot per task id, so one task's end never
/// takes another's pill down. The pill shows the newest live task; when that
/// task ends while the pill is still its own and nothing dictates, the
/// next-newest live task is shown again instead of a blank pill.
public struct TaskPills: Equatable {
    private struct Entry: Equatable {
        var task: String
        var text: String
        var slot: PillSlot
    }

    public struct Reveal: Equatable {
        public let task: String
        public let text: String
    }

    public struct Ended: Equatable {
        /// The ended task's own slot: `AppDelegate.endPill` runs it as usual.
        public let slot: PillSlot
        /// Set when a still-live task's pill must be shown now; then the slot
        /// is not ended (the reveal replaces the pill).
        public let reveal: Reveal?
    }

    private var entries: [Entry] = []

    public init() {}

    public var liveTasks: [String] { entries.map(\.task) }

    /// Records the task's pill right after its show. A live task begun again
    /// (its text re-shown after a reveal) keeps its place in the order.
    public mutating func begin(task: String, text: String, owner: Int) {
        var slot = PillSlot()
        slot.begin(owner: owner)
        if let at = entries.firstIndex(where: { $0.task == task }) {
            entries[at].text = text
            entries[at].slot = slot
        } else {
            entries.append(Entry(task: task, text: text, slot: slot))
        }
    }

    /// Removes the task. A reveal is asked for only when its pill is the one
    /// showing (`current` is its owner count), no dictation runs and another
    /// task is still live.
    public mutating func end(task: String, current: Int, dictation: DictationState) -> Ended {
        guard let at = entries.firstIndex(where: { $0.task == task }) else {
            return Ended(slot: PillSlot(), reveal: nil)
        }
        let gone = entries.remove(at: at)
        if gone.slot.stillOurs(current: current, dictation: dictation), let next = entries.last {
            return Ended(slot: gone.slot, reveal: Reveal(task: next.task, text: next.text))
        }
        return Ended(slot: gone.slot, reveal: nil)
    }
}
