import DictationCore
import Foundation

public struct DictationValues: Equatable {
    /// The key that dictates now (e.g. "⌃Space"); nil when none is registered. Changing it stays in the menu bar.
    public var keyTitle: String?
    public var mode: HotkeyMode
    public var sound: SoundWhileDictating
    /// The last dictations, newest first (memory only, as `DictationHistory` keeps them).
    public var recent: [String]

    public init(keyTitle: String?, mode: HotkeyMode, sound: SoundWhileDictating, recent: [String]) {
        self.keyTitle = keyTitle
        self.mode = mode
        self.sound = sound
        self.recent = recent
    }
}

public struct VoicesValues: Equatable {
    /// The voices registered on the daemon.
    public var voices: [String]
    /// nil is "Default voice"; `MenuSections.randomVoice` is "Random each time".
    public var russianVoice: String?
    public var englishVoice: String?

    public init(voices: [String], russianVoice: String?, englishVoice: String?) {
        self.voices = voices
        self.russianVoice = russianVoice
        self.englishVoice = englishVoice
    }
}

public struct AboutValues: Equatable {
    public var version: String
    public var engineRunning: Bool
    public var startAtLogin: Bool

    public init(version: String, engineRunning: Bool, startAtLogin: Bool) {
        self.version = version
        self.engineRunning = engineRunning
        self.startAtLogin = startAtLogin
    }
}

/// Everything the window shows. Plain values: the app fills them (lazily, when the window
/// opens), and the screenshot harness fills them with sample data.
public struct MainWindowData: Equatable {
    /// The list: newest first, without the texts.
    public var meetings: [MeetingInfo]
    /// How the last read of the list went; the list above is the last good one.
    public var meetingsLoad: MeetingsLoad
    /// Details already read, by meeting id; a row is read when it is selected.
    public var details: [String: MeetingDetail]
    /// Meetings whose detail is being read now, and why one could not be.
    public var detailLoading: Set<String>
    public var detailError: [String: String]
    /// Seconds into the recording that runs now; nil when none does.
    public var recordingElapsed: TimeInterval?
    /// A sentence for the last thing that did not go through (or one that did); the window shows it until dismissed.
    public var notice: String?
    public var meetingSettings: MeetingSettingsValues
    public var permissions: [PermissionItem]
    public var dictation: DictationValues
    public var voices: VoicesValues
    public var about: AboutValues

    public init(meetings: [MeetingInfo], meetingsLoad: MeetingsLoad = .loaded, details: [String: MeetingDetail],
                detailLoading: Set<String> = [], detailError: [String: String] = [:], recordingElapsed: TimeInterval? = nil,
                notice: String? = nil, meetingSettings: MeetingSettingsValues, permissions: [PermissionItem],
                dictation: DictationValues, voices: VoicesValues, about: AboutValues) {
        self.meetings = meetings
        self.meetingsLoad = meetingsLoad
        self.details = details
        self.detailLoading = detailLoading
        self.detailError = detailError
        self.recordingElapsed = recordingElapsed
        self.notice = notice
        self.meetingSettings = meetingSettings
        self.permissions = permissions
        self.dictation = dictation
        self.voices = voices
        self.about = about
    }
}

/// What the window asks the app to do. Every closure defaults to nothing, so a view renders
/// and answers clicks without the app behind it.
public struct MainWindowActions {
    public var refresh: () -> Void = {}
    public var selectMeeting: (String) -> Void = { _ in }
    public var startRecording: () -> Void = {}
    public var stopRecording: () -> Void = {}
    public var deleteMeeting: (String) -> Void = { _ in }
    public var renameMeeting: (String, String) -> Void = { _, _ in }
    public var copyNotes: (String) -> Void = { _ in }
    public var openMeetingFolder: (String) -> Void = { _ in }
    public var retryNotes: (String) -> Void = { _ in }
    public var retryVoices: (String) -> Void = { _ in }
    public var saveSpeakers: (String, SpeakerEdits) -> Void = { _, _ in }
    public var changeMeetingSetting: (MeetingSettingsModel.Change) -> Void = { _ in }
    public var openPermissionPane: (PermissionPane) -> Void = { _ in }
    public var chooseNotesFolder: () -> Void = {}
    public var openNotesFolder: () -> Void = {}
    public var downloadNotesWriter: () -> Void = {}
    public var checkForUpdates: () -> Void = {}
    public var setSound: (SoundWhileDictating) -> Void = { _ in }
    public var setHotkeyMode: (HotkeyMode) -> Void = { _ in }
    public var pickVoice: (VoiceSlot, String?) -> Void = { _, _ in }
    public var setStartAtLogin: (Bool) -> Void = { _ in }
    public var dismissNotice: () -> Void = {}

    public init() {}
}
