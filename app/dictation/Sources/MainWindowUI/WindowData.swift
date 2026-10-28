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
    /// The search over the meetings; `.idle` shows the days.
    public var search: MeetingSearchState
    /// The meeting audio that plays now.
    public var playback: PlaybackValues?
    public var meetingSettings: MeetingSettingsValues
    public var permissions: [PermissionItem]
    public var dictation: DictationValues
    public var voices: VoicesValues
    public var about: AboutValues

    public init(meetings: [MeetingInfo], meetingsLoad: MeetingsLoad = .loaded, details: [String: MeetingDetail],
                detailLoading: Set<String> = [], detailError: [String: String] = [:], recordingElapsed: TimeInterval? = nil,
                notice: String? = nil, search: MeetingSearchState = MeetingSearchState(), playback: PlaybackValues? = nil,
                meetingSettings: MeetingSettingsValues, permissions: [PermissionItem],
                dictation: DictationValues, voices: VoicesValues, about: AboutValues) {
        self.meetings = meetings
        self.meetingsLoad = meetingsLoad
        self.details = details
        self.detailLoading = detailLoading
        self.detailError = detailError
        self.recordingElapsed = recordingElapsed
        self.notice = notice
        self.search = search
        self.playback = playback
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
    /// The search field's text, as typed (the app debounces, cancels and retries).
    public var searchTyped: (String) -> Void = { _ in }
    public var retrySearch: () -> Void = {}
    /// A click on a transcript line: play that meeting from this line (the app decides whether it may).
    public var playTurn: (String, TranscriptTurn) -> Void = { _, _ in }
    public var togglePlayback: () -> Void = {}
    public var seekPlayback: (TimeInterval) -> Void = { _ in }
    /// The meeting is left, the window hides or the user stops it: the audio stops.
    public var stopPlayback: () -> Void = {}

    public init() {}
}
