import Foundation

/// How long a meeting's audio is kept after the call ends. The transcript and
/// the notes stay until the user deletes them. `rawValue` is the number of
/// days the daemon is told; 0 keeps the audio forever.
public enum MeetingRetention: Int, CaseIterable, Equatable {
    case week = 7
    case month = 30
    case quarter = 90
    case forever = 0

    public var days: Int { rawValue }

    public var titleKey: L10nKey {
        switch self {
        case .week: return .menuMeetingKeep7
        case .month: return .menuMeetingKeep30
        case .quarter: return .menuMeetingKeep90
        case .forever: return .menuMeetingKeepForever
        }
    }
}

/// The meeting settings the app keeps itself (UserDefaults). Retention is also
/// sent to the daemon, which deletes the audio; the folder, auto-start and the
/// name never leave the app.
public enum MeetingSettings {
    /// The feature flag: off until the release that ships meetings turns it on.
    public static let enabledKey = "meetingsEnabled"
    public static let folderKey = "meetingsFolder"
    public static let retentionKey = "meetingsRetentionDays"
    public static let autoStartKey = "meetingsAutoStart"
    public static let explainedKey = "meetingsExplained"
    public static let nameKey = "meetingsYourName"
    public static let exportedKey = "meetingsExported"

    public static func enabled(_ d: UserDefaults) -> Bool { d.bool(forKey: enabledKey) }

    /// Where the notes and transcripts are copied: the user's pick, else
    /// ~/Documents/ox-say Meetings.
    public static func folder(_ d: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = d.string(forKey: folderKey), path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return home.appendingPathComponent("Documents/ox-say Meetings", isDirectory: true)
    }

    public static func setFolder(_ url: URL, _ d: UserDefaults) { d.set(url.path, forKey: folderKey) }

    /// 30 days unless the user picked another value; an unknown stored value is 30 too.
    public static func retention(_ d: UserDefaults) -> MeetingRetention {
        guard d.object(forKey: retentionKey) != nil else { return .month }
        return MeetingRetention(rawValue: d.integer(forKey: retentionKey)) ?? .month
    }

    public static func setRetention(_ r: MeetingRetention, _ d: UserDefaults) { d.set(r.rawValue, forKey: retentionKey) }

    /// On unless the user turned it off: recording starts by itself when a call is detected.
    public static func autoStart(_ d: UserDefaults) -> Bool { (d.object(forKey: autoStartKey) as? Bool) ?? true }

    public static func setAutoStart(_ on: Bool, _ d: UserDefaults) { d.set(on, forKey: autoStartKey) }

    /// The one-time explanation (and consent reminder) has been shown.
    public static func explained(_ d: UserDefaults) -> Bool { d.bool(forKey: explainedKey) }

    public static func setExplained(_ d: UserDefaults) { d.set(true, forKey: explainedKey) }

    /// The label of the microphone channel in transcripts: the user's pick, else `fallback` (the macOS full name).
    public static func displayName(_ d: UserDefaults, fallback: String) -> String {
        let stored = d.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    public static func setDisplayName(_ name: String, _ d: UserDefaults) { d.set(name, forKey: nameKey) }

    /// Meeting ids already copied into the notes folder.
    public static func exported(_ d: UserDefaults) -> Set<String> { Set(d.stringArray(forKey: exportedKey) ?? []) }

    public static func markExported(_ id: String, _ d: UserDefaults) {
        var all = exported(d)
        all.insert(id)
        d.set(Array(all.sorted().suffix(500)), forKey: exportedKey)
    }
}
