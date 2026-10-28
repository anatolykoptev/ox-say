import DictationCore
import SwiftUI

/// Where a meeting opens when a search hit was clicked: the tab, and for a transcript hit the line.
public struct MeetingFocus: Equatable {
    public var meetingID: String
    public var destination: HitDestination
    /// Distinguishes two clicks on the same hit.
    public var serial: Int
}

/// The window's state: which section and which meeting are selected, and the data.
/// It holds no timer and no observer. The app calls `refresh` when the window opens and on
/// the events it already has (a meeting finished, a setting changed), so a closed window costs nothing.
@MainActor
public final class MainWindowModel: ObservableObject {
    @Published public var section: MainSection
    @Published public var selectedMeeting: String?
    @Published public var data: MainWindowData
    public var actions: MainWindowActions
    /// The search field's text.
    @Published public var queryText = ""
    /// The hit that was clicked last; the open meeting follows it.
    @Published public var focus: MeetingFocus?
    private var focusSerial = 0
    /// The tab a chosen meeting opens on.
    public var initialMeetingTab: MeetingTab = .notes
    /// The text the transcript's find opens with; the screenshot harness sets it, the app leaves it nil.
    public var initialFind: String?
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

    /// A click on a search hit: the meeting opens at the hit (Notes for a notes or title hit, the Transcript at its line).
    func openHit(_ meetingID: String, _ hit: SearchHit) {
        focusSerial += 1
        focus = MeetingFocus(meetingID: meetingID, destination: hit.destination, serial: focusSerial)
        selectedMeeting = meetingID
    }

    /// The meeting that is selected, with its texts when they were read.
    var selectedDetail: MeetingDetail? {
        guard let id = selectedMeeting else { return nil }
        if let d = data.details[id] { return d }
        return data.meetings.first { $0.id == id }.map { MeetingDetail(info: $0) }
    }

    /// Meetings off: the Meetings page offers to turn them on instead of an empty list.
    var meetingsEnabled: Bool { data.meetingSettings.enabled }

    /// What the Meetings page shows: one decision, in DictationCore.
    var pageState: MeetingsPageState {
        MeetingsPageState.of(enabled: meetingsEnabled, load: data.meetingsLoad, hasMeetings: !data.meetings.isEmpty,
                             recording: data.recordingElapsed != nil)
    }

    /// The Settings values with every edit passed on to the app, which saves it where it lives. The page shows the
    /// edit at once; the app reloads the values (and says why) when a save did not go through.
    var meetingSettings: Binding<MeetingSettingsValues> {
        Binding(get: { self.data.meetingSettings }, set: { self.setMeetingSettings($0) })
    }

    func setMeetingSettings(_ new: MeetingSettingsValues) {
        let old = data.meetingSettings
        data.meetingSettings = new
        for change in MeetingSettingsModel.changes(from: old, to: new) { actions.changeMeetingSetting(change) }
    }

    var sound: Binding<SoundWhileDictating> {
        Binding(get: { self.data.dictation.sound }, set: { self.data.dictation.sound = $0; self.actions.setSound($0) })
    }

    var hotkeyMode: Binding<HotkeyMode> {
        Binding(get: { self.data.dictation.mode }, set: { self.data.dictation.mode = $0; self.actions.setHotkeyMode($0) })
    }

    func voice(_ slot: VoiceSlot) -> Binding<String?> {
        Binding(get: { slot == .russian ? self.data.voices.russianVoice : self.data.voices.englishVoice },
                set: {
                    if slot == .russian { self.data.voices.russianVoice = $0 } else { self.data.voices.englishVoice = $0 }
                    self.actions.pickVoice(slot, $0)
                })
    }

    var startAtLogin: Binding<Bool> {
        Binding(get: { self.data.about.startAtLogin }, set: { self.data.about.startAtLogin = $0; self.actions.setStartAtLogin($0) })
    }
}
