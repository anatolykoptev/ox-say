import Foundation

/// Whether a task that put a pill up may still take it down. The overlay counts
/// the owners that took it — every show bumps the count — and a task keeps the
/// count it saw right after its show. Its finish is allowed only while that
/// count still stands (nobody since took the pill: a dictation, a message, a
/// speak) and no dictation is running: a completion landing mid-recording must
/// never take the dictation's pill away.
public enum PillOwnership {
    /// `owner` is the overlay's owner count captured right after the task's
    /// show (nil when the task never showed one); `current` is that count now;
    /// `dictation` is the controller's state.
    public static func shouldFinish(owner: Int?, current: Int, dictation: DictationState) -> Bool {
        guard let owner, owner == current else { return false }
        return dictation == .idle
    }
}
