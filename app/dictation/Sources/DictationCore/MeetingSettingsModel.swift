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
    public static func items(microphone: PermissionAuth, accessibility: Bool, notifications: PermissionAuth?) -> [PermissionItem] {
        // nil: the notification answer has not landed yet. No row, rather than a false "needs attention".
        func state(_ auth: PermissionAuth) -> PermissionState { auth == .authorized ? .allowed : .needsAttention }
        var rows = [
            PermissionItem(id: "mic", titleKey: .permMic, whyKey: .permMicWhy, symbol: "mic.fill", pane: .microphone,
                           state: state(microphone)),
            // No public call answers this one without a prompt: never "allowed" on a guess.
            PermissionItem(id: "audio", titleKey: .permSystemAudio, whyKey: .permSystemAudioWhy, symbol: "speaker.wave.2.fill",
                           pane: .systemAudio, state: .unknown),
            PermissionItem(id: "ax", titleKey: .permAccessibility, whyKey: .permAccessibilityWhy, symbol: "accessibility",
                           pane: .accessibility, state: accessibility ? .allowed : .needsAttention),
        ]
        if let notifications {
            rows.append(PermissionItem(id: "notifications", titleKey: .permNotifications, whyKey: .permNotificationsWhy,
                                       symbol: "bell.fill", pane: .notifications, state: state(notifications)))
        }
        return rows
    }
}

public enum NotesWriterState: Equatable {
    case ready
    /// The notes can run, but the last start of the notes model failed; the sentence says so. Notes stay available.
    case engineFailed(L10nKey)
    case missing
    /// Not downloaded, and the last download failed; the sentence says why, the Download action stays.
    case downloadFailed(L10nKey)
    case downloading(percent: Int)
    /// This Mac or this install cannot write notes; the text says why.
    case unavailable(L10nKey)
}

/// The OpenAI-compatible endpoint as the daemon answered it (`GET /v1/meetings/settings`): whether other local
/// apps may use the notes model, its loopback URL and per-install key, and the context the child runs with.
/// `verified` is false when the daemon could not be asked: the other fields then say nothing real.
public struct LLMEndpointValues: Equatable {
    public var on: Bool
    public var url: String
    public var key: String
    /// The context the notes child runs with under the endpoint, in tokens (0 until the daemon answers).
    public var contextTokens: Int
    public var verified: Bool

    public init(on: Bool = false, url: String = "", key: String = "", contextTokens: Int = 0, verified: Bool = false) {
        self.on = on
        self.url = url
        self.key = key
        self.contextTokens = contextTokens
        self.verified = verified
    }

    /// The values of a daemon answer; absent fields read as the feature's defaults (off, empty, unverified).
    public static func of(_ daemon: MeetingDaemonSettings?) -> LLMEndpointValues {
        guard let daemon else { return LLMEndpointValues() }
        return LLMEndpointValues(on: daemon.llmEndpointOn, url: daemon.llmEndpointURL, key: daemon.llmEndpointKey,
                                 contextTokens: daemon.llmEndpointCtx, verified: true)
    }
}

/// The meeting settings the Settings page shows. The folder, the global call mode, per-app picks and name are
/// `MeetingSettings` / `CallPolicy` values (UserDefaults); retention is the daemon's; the notes writer comes
/// from the daemon's status.
public struct MeetingSettingsValues: Equatable {
    public var enabled: Bool
    /// The global "when a call starts" mode; a per-app row that was never picked follows it.
    public var callMode: CallGlobalMode
    public var apps: [CallApp]
    public var folderPath: String
    /// True when macOS itself uploads the notes folder to iCloud (`ICloudSync`): the "nothing is
    /// uploaded" promise then needs its honest variant. False when unknown.
    public var folderSyncsICloud: Bool
    public var retention: MeetingRetention
    /// False when the daemon could not be asked: `retention` is the app's last copy, not a fact.
    public var retentionVerified: Bool
    public var yourName: String
    /// What the name falls back to (the macOS full name).
    public var yourNameFallback: String
    public var notesWriter: NotesWriterState
    /// The endpoint for other local apps, as the daemon answered it.
    public var llmEndpoint: LLMEndpointValues

    public init(enabled: Bool, callMode: CallGlobalMode, apps: [CallApp], folderPath: String, folderSyncsICloud: Bool = false,
                retention: MeetingRetention, retentionVerified: Bool = true, yourName: String, yourNameFallback: String,
                notesWriter: NotesWriterState, llmEndpoint: LLMEndpointValues = LLMEndpointValues()) {
        self.enabled = enabled
        self.callMode = callMode
        self.apps = apps
        self.folderPath = folderPath
        self.folderSyncsICloud = folderSyncsICloud
        self.retention = retention
        self.retentionVerified = retentionVerified
        self.yourName = yourName
        self.yourNameFallback = yourNameFallback
        self.notesWriter = notesWriter
        self.llmEndpoint = llmEndpoint
    }
}

public enum MeetingSettingsModel {
    /// One edit the user made on the page.
    public enum Change: Equatable {
        case enabled(Bool)
        case callMode(CallGlobalMode)
        case retention(MeetingRetention)
        /// A per-app pick, nil to return the row to "as set above".
        case mode(source: String, mode: CallAppMode?)
        case name(String)
        /// The OpenAI-compatible endpoint: other local apps may use the notes model, or not.
        case llmEndpoint(Bool)

        /// Whether the page must read everything again after the save. A name is typed letter by letter and must not.
        public var needsRefresh: Bool {
            switch self {
            case .enabled, .llmEndpoint: return true
            case .callMode, .retention, .mode, .name: return false
            }
        }
    }

    /// `daemon` is what the daemon reported, nil when it could not be asked; its retention wins because the daemon is
    /// what deletes the audio, and its endpoint fields are the only truthful answer for them. The folder's iCloud
    /// answer is read fresh on every load: a pick of a different folder moves it.
    public static func load(defaults d: UserDefaults, daemon: MeetingDaemonSettings?, notesWriter: NotesWriterState,
                            fullName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            probe: ICloudSync.Probe = ICloudSync.probe) -> MeetingSettingsValues {
        let folder = MeetingSettings.folder(d, home: home, probe: probe)
        return MeetingSettingsValues(
            enabled: MeetingSettings.enabled(d), callMode: MeetingSettings.callMode(d), apps: CallPolicy.apps(d),
            folderPath: folder.path, folderSyncsICloud: ICloudSync.syncs(folder, home: home, probe: probe),
            retention: daemon?.retention ?? MeetingSettings.retention(d),
            retentionVerified: daemon != nil, yourName: d.string(forKey: MeetingSettings.nameKey) ?? "", yourNameFallback: fullName, notesWriter: notesWriter,
            llmEndpoint: LLMEndpointValues.of(daemon))
    }

    /// The folder pick as one step: stored, then the values read again, so the page's iCloud
    /// answer is the new folder's own and a caller cannot save without the recompute.
    public static func folderPicked(_ url: URL, defaults d: UserDefaults, daemon: MeetingDaemonSettings?,
                                    notesWriter: NotesWriterState, fullName: String,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    probe: ICloudSync.Probe = ICloudSync.probe) -> MeetingSettingsValues {
        MeetingSettings.setFolder(url, d)
        return load(defaults: d, daemon: daemon, notesWriter: notesWriter,
                    fullName: fullName, home: home, probe: probe)
    }

    /// The edits that take `old` to `new`.
    public static func changes(from old: MeetingSettingsValues, to new: MeetingSettingsValues) -> [Change] {
        var out: [Change] = []
        if old.enabled != new.enabled { out.append(.enabled(new.enabled)) }
        if old.callMode != new.callMode { out.append(.callMode(new.callMode)) }
        if old.retention != new.retention { out.append(.retention(new.retention)) }
        if old.llmEndpoint.on != new.llmEndpoint.on { out.append(.llmEndpoint(new.llmEndpoint.on)) }
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
        case .callMode(let mode):
            MeetingSettings.setCallMode(mode, defaults)
        case .mode(let source, let mode):
            CallPolicy.setMode(mode, for: source, defaults)
        case .name(let name):
            MeetingSettings.setDisplayName(name.trimmingCharacters(in: .whitespacesAndNewlines), defaults)
        case .retention(let pick):
            do {
                try await client.setMeetingRetention(days: pick.days)
            } catch {
                return MeetingErrorText.sentence(error, action: .settings, text: text)
            }
            MeetingSettings.setRetention(pick, defaults)
        case .llmEndpoint(let on):
            do {
                try await client.setLLMEndpoint(on: on)
            } catch {
                return MeetingErrorText.sentence(error, action: .settings, text: text)
            }
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
