import Foundation

/// The System Settings pages the "Fix" buttons open.
public enum PermissionPane: String, CaseIterable, Equatable {
    case microphone
    case accessibility
    case systemAudio
    case notifications

    public var settingsURL: String {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone: return base + "Privacy_Microphone"
        case .accessibility: return base + "Privacy_Accessibility"
        case .systemAudio: return SystemAudioGuard.settingsURL
        case .notifications: return "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
    }
}

/// Whether a permission works. `unknown` is for the one macOS cannot be asked without showing a prompt (System Audio
/// Recording): the window says so instead of guessing.
public enum PermissionState: Equatable {
    case allowed
    case needsAttention
    case unknown
}

/// What macOS answers for a permission that can be read.
public enum PermissionAuth: Equatable {
    case authorized
    case denied
    case notDetermined
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

/// The Permissions rows from what the app read of macOS.
public enum PermissionModel {
    public static func items(microphone: PermissionAuth, accessibility: Bool, notifications: PermissionAuth) -> [PermissionItem] {
        func state(_ auth: PermissionAuth) -> PermissionState { auth == .authorized ? .allowed : .needsAttention }
        return [
            PermissionItem(id: "mic", titleKey: .permMic, whyKey: .permMicWhy, symbol: "mic.fill", pane: .microphone,
                           state: state(microphone)),
            // No public call answers this one without a prompt: never "allowed" on a guess.
            PermissionItem(id: "audio", titleKey: .permSystemAudio, whyKey: .permSystemAudioWhy, symbol: "speaker.wave.2.fill",
                           pane: .systemAudio, state: .unknown),
            PermissionItem(id: "ax", titleKey: .permAccessibility, whyKey: .permAccessibilityWhy, symbol: "accessibility",
                           pane: .accessibility, state: accessibility ? .allowed : .needsAttention),
            PermissionItem(id: "notifications", titleKey: .permNotifications, whyKey: .permNotificationsWhy, symbol: "bell.fill",
                           pane: .notifications, state: state(notifications)),
        ]
    }
}

public enum NotesWriterState: Equatable {
    case ready
    case missing
    case downloading(percent: Int)
    /// This Mac or this install cannot write notes; the text says why.
    case unavailable(L10nKey)
}

/// The meeting settings the Settings page shows. The folder, auto-start, per-app picks and name are `MeetingSettings` /
/// `CallPolicy` values (UserDefaults); retention is the daemon's; the notes writer comes from the daemon's status.
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

public enum MeetingSettingsModel {
    /// One edit the user made on the page.
    public enum Change: Equatable {
        case enabled(Bool)
        case autoStart(Bool)
        case retention(MeetingRetention)
        case mode(source: String, mode: CallAppMode)
        case name(String)
    }

    /// `daemonRetention` is what the daemon reported, nil when it could not be asked; it wins because the daemon is what
    /// deletes the audio.
    public static func load(defaults d: UserDefaults, daemonRetention: MeetingRetention?, notesWriter: NotesWriterState,
                            fullName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> MeetingSettingsValues {
        MeetingSettingsValues(
            enabled: MeetingSettings.enabled(d), autoStart: MeetingSettings.autoStart(d), apps: CallPolicy.apps(d),
            folderPath: MeetingSettings.folder(d, home: home).path, retention: daemonRetention ?? MeetingSettings.retention(d),
            yourName: d.string(forKey: MeetingSettings.nameKey) ?? "", yourNameFallback: fullName, notesWriter: notesWriter)
    }

    /// The edits that take `old` to `new`.
    public static func changes(from old: MeetingSettingsValues, to new: MeetingSettingsValues) -> [Change] {
        var out: [Change] = []
        if old.enabled != new.enabled { out.append(.enabled(new.enabled)) }
        if old.autoStart != new.autoStart { out.append(.autoStart(new.autoStart)) }
        if old.retention != new.retention { out.append(.retention(new.retention)) }
        if old.yourName != new.yourName { out.append(.name(new.yourName)) }
        for app in new.apps where old.apps.first(where: { $0.id == app.id })?.mode != app.mode {
            out.append(.mode(source: app.id, mode: app.mode))
        }
        return out
    }
}

/// Saves a `Change` where its setting lives. The one setting that lives in the daemon is sent first and remembered only
/// when the daemon took it.
public struct MeetingSettingsApplier {
    public var defaults: UserDefaults
    public var client: StudioClient

    public init(defaults: UserDefaults, client: StudioClient) {
        self.defaults = defaults
        self.client = client
    }

    /// nil when saved; else the sentence for the user (nothing was changed).
    public func apply(_ change: MeetingSettingsModel.Change, text: (L10nKey) -> String = { $0.text }) async -> String? {
        switch change {
        case .enabled(let on):
            defaults.set(on, forKey: MeetingSettings.enabledKey)
        case .autoStart(let on):
            MeetingSettings.setAutoStart(on, defaults)
        case .mode(let source, let mode):
            CallPolicy.setMode(mode, for: source, defaults)
        case .name(let name):
            MeetingSettings.setDisplayName(name.trimmingCharacters(in: .whitespacesAndNewlines), defaults)
        case .retention(let pick):
            do {
                try await client.setMeetingRetention(days: pick.days)
            } catch {
                return String(format: text(.settingsSaveFailed), MeetingErrorText.sentence(error, action: .settings, text: text))
            }
            MeetingSettings.setRetention(pick, defaults)
        }
        return nil
    }
}

/// The dictation settings the window edits. Both live in UserDefaults and are read by the dictation code itself.
public enum DictationSettings {
    public static let modeKey = "hotkeyMode"
    /// The read-aloud voice picked for Russian and for English text (absent = the daemon's default).
    public static let speakVoiceRUKey = "speakVoiceRU"
    public static let speakVoiceENKey = "speakVoiceEN"

    public static func sound(_ d: UserDefaults) -> SoundWhileDictating { SoundWhileDictatingSetting.mode(d) }

    /// Only through `choose`: a direct write of `pauseMusic` is migrated to Lower All Sound on the next read.
    public static func setSound(_ mode: SoundWhileDictating, _ d: UserDefaults) {
        SoundWhileDictatingSetting.choose(mode, in: d)
    }

    public static func mode(_ d: UserDefaults) -> HotkeyMode { d.string(forKey: modeKey).flatMap(HotkeyMode.init(rawValue:)) ?? .hold }

    public static func setMode(_ mode: HotkeyMode, _ d: UserDefaults) { d.set(mode.rawValue, forKey: modeKey) }
}
