import Foundation

/// Whether the daemon answers, decided from the polls the window already makes. One missed poll never turns the
/// page offline once the daemon has answered: a running job's progress or a finished result stays on screen and the
/// numbers are marked possibly old (`waiting`, which feeds `ProduceText.progressRow(serviceWaiting:)`). Nothing is
/// known before the first answer, so a first miss is offline at once: there is nothing on screen to lose.
public struct ReachTracker: Equatable {
    /// Consecutive missed polls that make a daemon that had answered unreachable.
    public static let missedPollsBeforeOffline = 2

    public private(set) var reach: DaemonReach = .unknown
    private var misses = 0

    public init() {}

    /// A poll is pending a second miss: the numbers on screen may be old.
    public var waiting: Bool { misses > 0 && reach == .reachable }

    public mutating func record(answered: Bool, sentence: @autoclosure () -> String) {
        if answered {
            misses = 0
            reach = .reachable
            return
        }
        misses += 1
        if reach == .reachable, misses < Self.missedPollsBeforeOffline { return }
        reach = .unreachable(sentence())
    }
}
