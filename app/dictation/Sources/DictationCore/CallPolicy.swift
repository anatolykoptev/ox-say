import Foundation

/// What OxSay does when a call starts in one app.
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

/// One row of the per-app list in Settings. `mode` is the user's own pick; nil is "as set above" — the row
/// follows the global mode (and the messenger rule under "Record automatically").
public struct CallApp: Equatable, Identifiable {
    public var id: String
    public var name: String
    /// A line under the name (which browsers a web call is read in); nil for none.
    public var noteKey: L10nKey?
    public var mode: CallAppMode?

    public init(id: String, name: String, noteKey: L10nKey? = nil, mode: CallAppMode?) {
        self.id = id
        self.name = name
        self.noteKey = noteKey
        self.mode = mode
    }
}

/// The per-app pick on top of `CallDetector`'s sources, layered on the global `CallGlobalMode`: an explicit
/// pick wins over ask/auto, `off` wins over everything, and under global auto the messengers — a microphone
/// in a browser or chat app can be anything — still ask first unless they were picked too.
public enum CallPolicy {
    public static let defaultsKey = "meetingsCallPolicy"

    /// Every source the detector returns, in the order Settings lists them. A test holds this to the detector's real
    /// output, so a new call app cannot be added there without a row here.
    public static let sources = ["zoom", "meet", "teams", "webex", "oxpulse", "slack", "facetime", "discord", "whatsapp", "telegram"]

    static let names = [
        "zoom": "Zoom", "meet": "Google Meet", "teams": "Microsoft Teams", "webex": "Webex", "oxpulse": "OxPulse",
        "slack": "Slack", "facetime": "FaceTime", "discord": "Discord", "whatsapp": "WhatsApp", "telegram": "Telegram",
    ]

    /// The display name of a call source, for prompts that name the detected app ("Zoom call — record it?").
    public static func name(for source: String) -> String { names[source] ?? source }

    /// Apps whose calls are also read in a browser tab.
    static let browserNotes: [String: L10nKey] = ["meet": .settingsAppsBrowsers, "oxpulse": .settingsAppsBrowsers]

    /// The ranking order the detector uses for a source nobody picked anything about: the work-call sources
    /// first, the messengers last — under global auto this is also their effective mode.
    public static func defaultMode(_ source: String) -> CallAppMode {
        CallDetector.autoStartSources.contains(source) ? .auto : .ask
    }

    /// The stored pick for an app, or nil when the row follows the global mode.
    public static func pickedMode(for source: String, _ d: UserDefaults) -> CallAppMode? {
        (d.dictionary(forKey: defaultsKey) as? [String: String])?[source].flatMap(CallAppMode.init(rawValue:))
    }

    /// A pick, or nil to return the row to "as set above".
    public static func setMode(_ mode: CallAppMode?, for source: String, _ d: UserDefaults) {
        var all = (d.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[source] = mode?.rawValue
        d.set(all, forKey: defaultsKey)
    }

    /// What a call in `source` actually does: the pick, else the global mode — with the messenger exception
    /// under auto — and global `off` above it all.
    public static func effectiveMode(for source: String, global: CallGlobalMode, picked: CallAppMode?) -> CallAppMode {
        if let picked { return global == .off ? .never : picked }
        switch global {
        case .off: return .never
        case .ask: return .ask
        case .auto: return defaultMode(source)
        }
    }

    public static func apps(_ d: UserDefaults) -> [CallApp] {
        sources.map { CallApp(id: $0, name: name(for: $0), noteKey: browserNotes[$0], mode: pickedMode(for: $0, d)) }
    }

    /// The rows with every app on its default, for a picture that must not read anybody's settings.
    public static func defaultApps() -> [CallApp] {
        sources.map { CallApp(id: $0, name: name(for: $0), noteKey: browserNotes[$0], mode: nil) }
    }
}

extension MeetingPolicy {
    /// A detected call, by the global mode and the app's pick (`effectiveMode`). Auto still does not start
    /// while an update installs, and "Don't record" is never offered either, whatever else is true.
    public static func onCallStarted(source: String, global: CallGlobalMode, picked: CallAppMode?, installing: Bool) -> CallStart {
        switch CallPolicy.effectiveMode(for: source, global: global, picked: picked) {
        case .never: return .ignore
        case .auto: return installing ? .prompt : .start
        case .ask: return .prompt
        }
    }
}
