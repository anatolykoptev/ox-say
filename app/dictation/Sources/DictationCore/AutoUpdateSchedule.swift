import Foundation

/// What the app remembers between launches about its own update checks.
public struct AutoUpdateState: Equatable {
    public static let lastCheckKey = "lastUpdateCheck"
    public static let lastNotifiedKey = "lastUpdateNotifiedVersion"

    /// When a check last got an answer from GitHub (a failed one does not count).
    public var lastCheck: Date?
    /// The release tag the user was last told about.
    public var lastNotifiedVersion: String?

    public init(lastCheck: Date? = nil, lastNotifiedVersion: String? = nil) {
        self.lastCheck = lastCheck
        self.lastNotifiedVersion = lastNotifiedVersion
    }

    public static func load(from defaults: UserDefaults) -> AutoUpdateState {
        AutoUpdateState(
            lastCheck: (defaults.object(forKey: lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:)),
            lastNotifiedVersion: defaults.string(forKey: lastNotifiedKey))
    }

    public func save(to defaults: UserDefaults) {
        if let lastCheck {
            defaults.set(lastCheck.timeIntervalSince1970, forKey: Self.lastCheckKey)
        } else {
            defaults.removeObject(forKey: Self.lastCheckKey)
        }
        if let lastNotifiedVersion {
            defaults.set(lastNotifiedVersion, forKey: Self.lastNotifiedKey)
        } else {
            defaults.removeObject(forKey: Self.lastNotifiedKey)
        }
    }
}

/// The background update check: when to ask GitHub and what a release changes
/// in the menu. Nothing here installs; the row it offers runs the same install
/// the manual "Check for Updates…" prompt runs, on a click.
public enum AutoUpdateSchedule {
    /// The first check, after launch.
    public static let firstDelay: TimeInterval = 60
    /// Between two answered checks.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// How often the app looks at the clock; a failed check is retried at the
    /// next tick, an answered one waits out `interval`.
    public static let tick: TimeInterval = 60 * 60

    /// What one answered or failed check does to the menu.
    public enum Outcome: Equatable {
        /// A newer release exists: show its row; `notify` when the user has
        /// not yet been told about this version.
        case offer(tag: String, notify: Bool)
        /// The local version is current: take the row away.
        case clear
        /// The check failed: leave the menu as it was.
        case unchanged
    }

    /// Whether a check is due. A process that has not had an answer yet is
    /// always due, so the row is rebuilt after every relaunch without storing
    /// the release, and a launch check that failed or was skipped (no network
    /// yet, a manual check running) is retried at the next slot instead of
    /// waiting out the previous process's answer. Once this process got one,
    /// every slot (the tick, a wake) waits out `interval`. A last check in the
    /// future (the clock moved back) is due.
    public static func shouldCheck(now: Date, lastCheck: Date?, answeredThisProcess: Bool) -> Bool {
        if !answeredThisProcess { return true }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Folds a fetch into the menu outcome and the persisted state. The
    /// version compare is `UpdatePrompt.make`'s, the one the manual check uses.
    public static func apply(fetch: Result<(tag: String, url: URL?, body: String), UpdateError>,
                             local: String, now: Date, state: inout AutoUpdateState) -> Outcome {
        switch UpdatePrompt.make(local: local, fetch: fetch) {
        case .failed:
            return .unchanged
        case .upToDate:
            state.lastCheck = now
            return .clear
        case .available(let remote, _, _, _):
            state.lastCheck = now
            let notify = state.lastNotifiedVersion != remote
            if notify { state.lastNotifiedVersion = remote }
            return .offer(tag: remote, notify: notify)
        }
    }

    /// "v0.1.23" whether the tag came with its "v" or not.
    public static func displayVersion(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("v") || t.hasPrefix("V") ? "v" + t.dropFirst() : "v" + t
    }
}
