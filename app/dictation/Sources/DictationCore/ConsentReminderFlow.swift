import Foundation

/// When the one-time consent reminder counts as given: only when the person ACKNOWLEDGED it — OK pressed on the plate
/// that showed it, or the reminder notification opened. A notification that was handed to the system proves nothing
/// (Focus, banner style None, Notification Center closed), and a plate shown but not answered (the recording stopped, the
/// app quit) is asked again at the next recording.
public enum ConsentReminderFlow {
    public enum Step: Equatable {
        case explained
        case askAgain
    }

    public static func step(plateShown: Bool, plateOK: Bool, notificationOpened: Bool) -> Step {
        (plateShown && plateOK) || notificationOpened ? .explained : .askAgain
    }
}
