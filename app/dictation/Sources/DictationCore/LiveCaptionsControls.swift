import Foundation

/// What a click on the recording plate opens. The plate is shown only while a recording runs, but the recording can
/// stop between the draw and the click: then the Meetings list opens, never a crash and never a page for a meeting
/// that is not being recorded.
public enum PlateClick {
    public static func route(recordingID: String?) -> MainRoute {
        MainRoute(section: .meetings, meetingID: recordingID.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The line under the recording's row in the Meetings list: its last live caption.
public enum MeetingRowCaption {
    /// One row line, so a long caption is cut here (the view then truncates to the width it has).
    public static let maxCharacters = 160

    /// nil when the row looks as it always did: the meeting is not recording, captions are off in the daemon, or no
    /// line has arrived yet. The text is shown, never logged.
    public static func line(info: MeetingInfo, feed: LiveFeed?) -> String? {
        guard info.status == .recording, let feed, feed.state?.enabled != false, let last = feed.captions.last else { return nil }
        let flat = last.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > maxCharacters else { return flat }
        return String(flat.prefix(maxCharacters - 1)) + "…"
    }
}
