import DictationCore
import SwiftUI

/// The window's state: which section and which meeting are selected, and the data.
/// It holds no timer and no observer. The app calls `refresh` when the window opens and on
/// the events it already has (a meeting finished, a setting changed), so a closed window costs nothing.
@MainActor
public final class MainWindowModel: ObservableObject {
    @Published public var section: MainSection
    @Published public var selectedMeeting: String?
    @Published public var data: MainWindowData
    public var actions: MainWindowActions
    /// The tab a chosen meeting opens on.
    public var initialMeetingTab: MeetingTab = .notes
    /// Whether Settings shows the per-app list; it starts folded, because most people never open it.
    @Published public var appsExpanded = false
    /// "Now", for the day headings; a test or the harness pins it.
    public var clock: () -> Date = { Date() }

    public init(data: MainWindowData, actions: MainWindowActions = MainWindowActions(),
                section: MainSection = .meetings, selectedMeeting: String? = nil) {
        self.data = data
        self.actions = actions
        self.section = section
        self.selectedMeeting = selectedMeeting
    }

    /// The meeting that is selected, with its texts when they were read.
    var selectedDetail: MeetingDetail? {
        guard let id = selectedMeeting else { return nil }
        if let d = data.details[id] { return d }
        return data.meetings.first { $0.id == id }.map { MeetingDetail(info: $0) }
    }

    /// Meetings off: the Meetings page offers to turn them on instead of an empty list.
    var meetingsEnabled: Bool { data.meetingSettings.enabled }
}
