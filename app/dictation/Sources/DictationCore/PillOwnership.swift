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

/// How long a pill message stays up.
public enum PillTiming {
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
