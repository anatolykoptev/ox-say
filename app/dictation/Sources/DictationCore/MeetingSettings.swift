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

/// The settings the daemon keeps for meetings (`GET /v1/meetings/settings`): today only how long audio stays.
public struct MeetingDaemonSettings: Equatable {
    public var retentionDays: Int

    public init(retentionDays: Int) { self.retentionDays = retentionDays }

    public var retention: MeetingRetention { MeetingRetention(rawValue: retentionDays) ?? .month }

    /// nil for an answer without a period, or with one that is not a choice: a guess could show "30 days" over a
    /// "never" the user picked.
    public static func decode(_ data: Data) -> MeetingDaemonSettings? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = obj["retention_days"] as? Int, MeetingRetention(rawValue: days) != nil else { return nil }
        return MeetingDaemonSettings(retentionDays: days)
    }
}

/// The global "when a call starts" choice: ask about each call, record automatically, or do not watch
/// for calls at all. A per-app pick (`CallPolicy.setMode`) overrides ask/auto; `off` overrides everything.
public enum CallGlobalMode: String, CaseIterable, Sendable {
    case ask = "ask"
    case auto = "auto"
    case off = "off"

    public var titleKey: L10nKey {
        switch self {
        case .ask: return .settingsAppsAsk
        case .auto: return .settingsAppsAuto
        case .off: return .settingsCallOff
        }
    }
}

/// The meeting settings the app keeps itself (UserDefaults). Retention is also
/// sent to the daemon, which deletes the audio; the folder, the call mode and
/// the name never leave the app.
public enum MeetingSettings {
    /// The feature flag: on unless the user turned meetings off.
    public static let enabledKey = "meetingsEnabled"
    public static let folderKey = "meetingsFolder"
    public static let retentionKey = "meetingsRetentionDays"
    /// The global call mode (`CallGlobalMode`). The old `meetingsAutoStart` boolean is dead: the feature
    /// itself shipped off, so nothing it could have meant is still true — the key is simply not read.
    public static let callModeKey = "meetingsCallMode"
    public static let explainedKey = "meetingsExplained"
    public static let nameKey = "meetingsYourName"
    public static let exportedKey = "meetingsExported"
    public static let exportPathsKey = "meetingsExportPaths"
    public static let exportStaleKey = "meetingsExportStale"
    public static let exportHashesKey = "meetingsExportHashes"

    /// Meetings ship on: only a stored `false` turns them off.
    public static func enabled(_ d: UserDefaults) -> Bool { (d.object(forKey: enabledKey) as? Bool) ?? true }

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

    /// The global call mode; an unset or unknown value asks first — nothing records by itself.
    public static func callMode(_ d: UserDefaults) -> CallGlobalMode {
        d.string(forKey: callModeKey).flatMap(CallGlobalMode.init(rawValue:)) ?? .ask
    }

    public static func setCallMode(_ mode: CallGlobalMode, _ d: UserDefaults) { d.set(mode.rawValue, forKey: callModeKey) }

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

    /// Where each exported meeting's copy went (id -> folder path), so a rename can rewrite it in place.
    public static func exportPath(_ id: String, _ d: UserDefaults) -> String? {
        (d.dictionary(forKey: exportPathsKey) as? [String: String])?[id]
    }

    public static func setExportPath(_ id: String, _ path: String, _ d: UserDefaults) {
        var all = (d.dictionary(forKey: exportPathsKey) as? [String: String]) ?? [:]
        all[id] = path
        // the newest 500 by id: ids start with the date
        for key in all.keys.sorted().dropLast(500) { all[key] = nil }
        d.set(all, forKey: exportPathsKey)
    }

    /// Meetings whose speakers changed after they were copied: the copy is of the old names.
    public static func exportStale(_ d: UserDefaults) -> Set<String> { Set(d.stringArray(forKey: exportStaleKey) ?? []) }

    public static func setExportStale(_ id: String, _ stale: Bool, _ d: UserDefaults) {
        var all = exportStale(d)
        if stale { all.insert(id) } else { all.remove(id) }
        d.set(Array(all.sorted().suffix(500)), forKey: exportStaleKey)
    }

    /// SHA-256 of each file `NotesExport` wrote for a meeting (file name -> hex), so a refresh can tell a copy the
    /// user edited from one it wrote itself.
    public static func exportHashes(_ id: String, _ d: UserDefaults) -> [String: String] {
        ((d.dictionary(forKey: exportHashesKey) as? [String: [String: String]]) ?? [:])[id] ?? [:]
    }

    public static func setExportHashes(_ id: String, _ hashes: [String: String], _ d: UserDefaults) {
        var all = (d.dictionary(forKey: exportHashesKey) as? [String: [String: String]]) ?? [:]
        all[id] = hashes
        for key in all.keys.sorted().dropLast(500) { all[key] = nil }
        d.set(all, forKey: exportHashesKey)
    }
}
