import DictationCore
import Foundation

/// The System Settings pages the "Fix" buttons open.
public enum PermissionPane: String, CaseIterable, Equatable {
    case microphone
    case accessibility
    case systemAudio
    case automation

    public var settingsURL: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone: return base + "Privacy_Microphone"
        case .accessibility: return base + "Privacy_Accessibility"
        case .systemAudio: return base + "Privacy_ScreenCapture"
        case .automation: return base + "Privacy_Automation"
        }
    }
}

/// Whether a permission works. `unknown` is for the two macOS cannot be asked
/// without showing a prompt (system audio, automation): the window says so
/// instead of guessing.
public enum PermissionState: Equatable {
    case allowed
    case needsAttention
    case unknown
}

public struct PermissionItem: Equatable, Identifiable {
    public var id: String
    public var titleKey: L10nKey
    public var whyKey: L10nKey
    public var symbol: String
    public var pane: PermissionPane
    public var state: PermissionState

    public init(id: String, titleKey: L10nKey, whyKey: L10nKey, symbol: String, pane: PermissionPane, state: PermissionState) {
        self.id = id
        self.titleKey = titleKey
        self.whyKey = whyKey
        self.symbol = symbol
        self.pane = pane
        self.state = state
    }
}

/// What the window does with a call app it recognises.
public enum CallAppMode: String, CaseIterable, Equatable {
    case auto
    case ask
    case never

    public var titleKey: L10nKey {
        switch self {
        case .auto: return .settingsAppsAuto
        case .ask: return .settingsAppsAsk
        case .never: return .settingsAppsNever
        }
    }
}

public struct CallApp: Equatable, Identifiable {
    public var id: String
    public var name: String
    /// A line under the name (which browsers a web call is read in); nil for none.
    public var noteKey: L10nKey?
    public var mode: CallAppMode

    public init(id: String, name: String, noteKey: L10nKey? = nil, mode: CallAppMode) {
        self.id = id
        self.name = name
        self.noteKey = noteKey
        self.mode = mode
    }
}

public enum NotesWriterState: Equatable {
    case ready
    case missing
    case downloading(percent: Int)
    /// This Mac or this install cannot write notes; the text says why.
    case unavailable(L10nKey)
}

/// The meeting settings the Settings page shows. The folder, retention, auto-start and name are
/// `MeetingSettings` values (UserDefaults); the rest comes from the daemon or macOS.
public struct MeetingSettingsValues: Equatable {
    public var enabled: Bool
    public var autoStart: Bool
    public var apps: [CallApp]
    public var folderPath: String
    public var retention: MeetingRetention
    public var yourName: String
    /// What the name falls back to (the macOS full name).
    public var yourNameFallback: String
    public var notesWriter: NotesWriterState

    public init(enabled: Bool, autoStart: Bool, apps: [CallApp], folderPath: String, retention: MeetingRetention,
                yourName: String, yourNameFallback: String, notesWriter: NotesWriterState) {
        self.enabled = enabled
        self.autoStart = autoStart
        self.apps = apps
        self.folderPath = folderPath
        self.retention = retention
        self.yourName = yourName
        self.yourNameFallback = yourNameFallback
        self.notesWriter = notesWriter
    }
}

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

public enum DictationModeChoice: String, CaseIterable, Equatable {
    case hold
    case toggle
}

public struct DictationValues: Equatable {
    public var keys: [KeyChoice]
    public var keyID: String
    public var mode: DictationModeChoice
    public var sound: SoundWhileDictating
    /// The last dictations, newest first (memory only, as `DictationHistory` keeps them).
    public var recent: [String]

    public init(keys: [KeyChoice], keyID: String, mode: DictationModeChoice, sound: SoundWhileDictating, recent: [String]) {
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
