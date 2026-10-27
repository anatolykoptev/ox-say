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

/// One row of the per-app list in Settings.
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

/// The per-app pick on top of `CallDetector`'s sources. The default of an app that was never picked is today's
/// behaviour: the sources in `CallDetector.autoStartSources` record by themselves, every other one asks first.
public enum CallPolicy {
    public static let defaultsKey = "meetingsCallPolicy"

    /// Every source the detector returns, in the order Settings lists them. A test holds this to the detector's real
    /// output, so a new call app cannot be added there without a row here.
    public static let sources = ["zoom", "meet", "teams", "webex", "oxpulse", "slack", "facetime", "discord", "whatsapp", "telegram"]

    static let names = [
        "zoom": "Zoom", "meet": "Google Meet", "teams": "Microsoft Teams", "webex": "Webex", "oxpulse": "OxPulse",
        "slack": "Slack", "facetime": "FaceTime", "discord": "Discord", "whatsapp": "WhatsApp", "telegram": "Telegram",
    ]

    /// Apps whose calls are also read in a browser tab.
    static let browserNotes: [String: L10nKey] = ["meet": .settingsAppsBrowsers, "oxpulse": .settingsAppsBrowsers]

    public static func defaultMode(_ source: String) -> CallAppMode {
        CallDetector.autoStartSources.contains(source) ? .auto : .ask
    }

    public static func mode(for source: String, _ d: UserDefaults) -> CallAppMode {
        let stored = (d.dictionary(forKey: defaultsKey) as? [String: String])?[source]
        return stored.flatMap(CallAppMode.init(rawValue:)) ?? defaultMode(source)
    }

    public static func setMode(_ mode: CallAppMode, for source: String, _ d: UserDefaults) {
        var all = (d.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[source] = mode.rawValue
        d.set(all, forKey: defaultsKey)
    }

    public static func apps(_ d: UserDefaults) -> [CallApp] {
        sources.map { CallApp(id: $0, name: names[$0] ?? $0, noteKey: browserNotes[$0], mode: mode(for: $0, d)) }
    }

    /// The rows with every app on its default, for a picture that must not read anybody's settings.
    public static func defaultApps() -> [CallApp] {
        sources.map { CallApp(id: $0, name: names[$0] ?? $0, noteKey: browserNotes[$0], mode: defaultMode($0)) }
    }
}

extension MeetingPolicy {
    /// A detected call, by its app's pick. Auto still needs the master switch and no install in progress; "Don't record"
    /// is never offered either, whatever else is true.
    public static func onCallStarted(source: String, mode: CallAppMode, autoStart: Bool, installing: Bool) -> CallStart {
        switch mode {
        case .never: return .ignore
        case .auto: return autoStart && !installing ? .start : .prompt
        case .ask: return .prompt
        }
    }
}
