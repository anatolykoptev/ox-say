import Foundation

/// The words of the one-time consent reminder before the first recording. The audio-retention sentence is built
/// from the user's actual setting, not a number typed into the translation.
public enum ConsentReminder {
    public static func body(retention: MeetingRetention, text: (L10nKey) -> String) -> String {
        let keep = retention == .forever
            ? text(.meetingRemindKeepForever)
            : String(format: text(.meetingRemindKeepDays), retention.days)
        return String(format: text(.meetingRemindBody), keep)
    }
}
