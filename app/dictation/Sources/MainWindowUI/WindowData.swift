import DictationCore
import Foundation

public struct KeyChoice: Equatable, Identifiable {
    public var id: String
    public var title: String
    /// macOS uses this combination itself; the row is greyed out.
    public var takenByMac: Bool

    public init(id: String, title: String, takenByMac: Bool = false) {
        self.id = id
        self.title = title
        self.takenByMac = takenByMac
    }
}

public struct DictationValues: Equatable {
    public var keys: [KeyChoice]
    public var keyID: String
    public var mode: HotkeyMode
    public var sound: SoundWhileDictating
    /// The last dictations, newest first (memory only, as `DictationHistory` keeps them).
    public var recent: [String]

    public init(keys: [KeyChoice], keyID: String, mode: HotkeyMode, sound: SoundWhileDictating, recent: [String]) {
        self.keys = keys
        self.keyID = keyID
        self.mode = mode
        self.sound = sound
        self.recent = recent
    }
}

public enum StudioVoiceState: Equatable {
    case installed
    case missing
    case unavailable(String)
}

public struct VoicesValues: Equatable {
    public var speakKeys: [KeyChoice]
    public var speakKeyID: String
    /// The voices registered on the daemon.
    public var voices: [String]
    /// nil is "Default voice"; `MenuSections.randomVoice` is "Random each time".
    public var russianVoice: String?
    public var englishVoice: String?
    public var studio: StudioVoiceState
    public var hasVoiceoversFolder: Bool

    public init(speakKeys: [KeyChoice], speakKeyID: String, voices: [String], russianVoice: String?, englishVoice: String?,
                studio: StudioVoiceState, hasVoiceoversFolder: Bool) {
        self.speakKeys = speakKeys
        self.speakKeyID = speakKeyID
        self.voices = voices
        self.russianVoice = russianVoice
        self.englishVoice = englishVoice
        self.studio = studio
        self.hasVoiceoversFolder = hasVoiceoversFolder
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

/// One meeting as the detail pane needs it: the daemon's meeting (with the texts) and its speakers.
public struct MeetingDetail: Equatable {
    public var info: MeetingInfo
    /// nil until the speakers were read.
    public var speakers: SpeakersState?

    public init(info: MeetingInfo, speakers: SpeakersState? = nil) {
        self.info = info
        self.speakers = speakers
    }
}

/// Everything the window shows. Plain values: the app fills them (lazily, when the window
/// opens), and the screenshot harness fills them with sample data.
public struct MainWindowData: Equatable {
    /// The list: newest first, without the texts.
    public var meetings: [MeetingInfo]
    /// Details already read, by meeting id; a row is read when it is selected.
    public var details: [String: MeetingDetail]
    /// Seconds into the recording that runs now; nil when none does.
    public var recordingElapsed: TimeInterval?
    public var meetingSettings: MeetingSettingsValues
    public var permissions: [PermissionItem]
    public var dictation: DictationValues
    public var voices: VoicesValues
    public var about: AboutValues

    public init(meetings: [MeetingInfo], details: [String: MeetingDetail], recordingElapsed: TimeInterval? = nil,
                meetingSettings: MeetingSettingsValues, permissions: [PermissionItem], dictation: DictationValues,
                voices: VoicesValues, about: AboutValues) {
        self.meetings = meetings
        self.details = details
        self.recordingElapsed = recordingElapsed
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
    public var copyNotes: (String) -> Void = { _ in }
    public var openMeetingFolder: (String) -> Void = { _ in }
    public var retryNotes: (String) -> Void = { _ in }
    public var saveSpeakers: (String, SpeakerEdits) -> Void = { _, _ in }
    public var openPermissionPane: (PermissionPane) -> Void = { _ in }
    public var chooseNotesFolder: () -> Void = {}
    public var openNotesFolder: () -> Void = {}
    public var downloadNotesWriter: () -> Void = {}
    public var checkForUpdates: () -> Void = {}
    public var copyDictation: (String) -> Void = { _ in }
    public var pasteLastDictation: () -> Void = {}
    public var createVoice: () -> Void = {}
    public var newVoiceover: () -> Void = {}
    public var openVoiceoversFolder: () -> Void = {}
    public var installStudioVoice: () -> Void = {}

    public init() {}
}
