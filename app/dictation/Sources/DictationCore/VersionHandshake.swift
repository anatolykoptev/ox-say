import Foundation

/// Keeps the running app, the bundle on disk and the daemon on one version.
/// A pure decision table: the app feeds it the three version strings — the
/// on-disk one read from Contents/Info.plist, never the cached Bundle.main —
/// and performs the action the table returns.
public enum VersionHandshake {
    /// What a run of the table decides.
    public enum Action: Equatable {
        /// The running app is older than the bundle on disk: `open -n` the
        /// bundle path, which launches the newer copy now sitting there,
        /// then this process ends.
        case relaunchSelf
        /// The daemon answers a different version than the bundle on disk:
        /// `launchctl kickstart -k` the agent, then re-read /status.
        case kickstartDaemon
        /// The daemon still differs after `maxKickstarts` tries: offer the
        /// Repair row, which reinstalls `target` — the on-disk bundle's
        /// version, the authority here.
        case offerRepair(target: String)
        /// Nothing to do: everything agrees, the daemon is unreachable, or a
        /// dev/unparseable version would make any action a guess.
        case none
    }

    /// The argv behind kickstartDaemon: launchd's service-target form
    /// `gui/<uid>/<label>`; the label defaults to the installer's own.
    public static func kickstartCommand(uid: UInt32, label: String = DaemonAddress.agentLabel) -> [String] {
        ["/bin/launchctl", "kickstart", "-k", "gui/\(uid)/\(label)"]
    }

    /// Kickstarts tried against one mismatch before Repair is offered. One
    /// almost always lands the bundle's daemon; beyond this is a repair, not
    /// a loop.
    public static let maxKickstarts = 2

    /// The pause after a kickstart before /status is re-read.
    public static let kickstartBackoff: TimeInterval = 2

    /// The one table: `app` is the running process's version, `disk` the
    /// bundle's Info.plist on disk, `daemon` the /status version (nil when
    /// the daemon did not answer), `kickstarts` how many kickstarts this
    /// mismatch has already spent.
    public static func decide(app: String?, disk: String?, daemon: String?, kickstarts: Int) -> Action {
        guard let disk, let running = release(app), let bundle = release(disk) else { return .none }
        if running.lexicographicallyPrecedes(bundle) { return .relaunchSelf }
        guard let service = release(daemon) else { return .none }
        if service == bundle { return .none }
        if kickstarts < maxKickstarts { return .kickstartDaemon }
        return .offerRepair(target: "\(bundle[0]).\(bundle[1]).\(bundle[2])")
    }

    /// The daemon confirmed the bundle's version: an episode ends and the
    /// kickstart count resets. An unreachable or dev answer confirms nothing.
    public static func agrees(daemon: String?, disk: String?) -> Bool {
        guard let service = release(daemon), let bundle = release(disk) else { return false }
        return service == bundle
    }

    /// A version as a comparable triple, or nil: "0.0.0" is a dev build and
    /// anything not three numbers (the daemon's "dev", a garbage tag) is not
    /// a release either — the handshake never acts on either.
    static func release(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        var v = UpdateInstaller.normalized(version)
        // A suffix like -beta1 or +build is not part of the numeric compare.
        if let cut = v.firstIndex(where: { "-+".contains($0) }) { v = String(v[..<cut]) }
        let parts = v.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2],
              a != 0 || b != 0 || c != 0 else { return nil }
        return [a, b, c]
    }
}
