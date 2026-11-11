import Foundation

/// When the one-time consent reminder counts as given: only once its BODY has been put in front of the user, by a
/// delivered notification or, when notifications are not allowed, on the plate. The title alone does not count, and
/// neither does an attempt nothing surfaced: the reminder is asked again at the next recording.
public enum ConsentReminderFlow {
    public enum Step: Equatable {
        case explained
        /// The notification was not delivered: the plate shows the full text.
        case showOnPlate
        /// Neither surfaced it.
        case askAgain
    }

    public static func afterPost(delivered: Bool) -> Step { delivered ? .explained : .showOnPlate }

    public static func afterPlate(shown: Bool) -> Step { shown ? .explained : .askAgain }
}
