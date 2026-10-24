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
        /// The app or the daemon has work in flight — a dictation, a speak
        /// or a design a relaunch or restart would kill mid-way. The action
        /// waits for the next idle pass and a deferral spends no kickstart.
        case deferUntilIdle
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

    /// The most the launchctl kickstart command itself may take before it
    /// is ended — launchctl answers at once when launchd is healthy, and a
    /// wedged one must not hang the pass.
    public static let kickstartTimeout: TimeInterval = 5

    /// The one table: `app` is the running process's version, `disk` the
    /// bundle's Info.plist on disk, `daemon` the /status version (nil when
    /// the daemon did not answer), `kickstarts` how many kickstarts this
    /// mismatch has already spent. `serviceIdle` and `appIdle` are the busy
    /// guards — the daemon's own report and the app's: a relaunch ends this
    /// process and a kickstart restarts the daemon, so with work in flight
    /// on either side the action defers to the next idle pass instead. The
    /// Repair row is user-initiated, so it is offered regardless.
    public static func decide(app: String?, disk: String?, daemon: String?, kickstarts: Int,
                              serviceIdle: Bool, appIdle: Bool) -> Action {
        guard let disk, let running = release(app), let bundle = release(disk) else { return .none }
        if running.lexicographicallyPrecedes(bundle) {
            return serviceIdle && appIdle ? .relaunchSelf : .deferUntilIdle
        }
        guard let service = release(daemon) else { return .none }
        if service == bundle { return .none }
        if kickstarts < maxKickstarts {
            return serviceIdle && appIdle ? .kickstartDaemon : .deferUntilIdle
        }
        return .offerRepair(target: "\(bundle[0]).\(bundle[1]).\(bundle[2])")
    }

    /// The daemon confirmed the bundle's version: an episode ends and the
    /// kickstart count resets. An unreachable or dev answer confirms nothing.
    public static func agrees(daemon: String?, disk: String?) -> Bool {
        guard let service = release(daemon), let bundle = release(disk) else { return false }
        return service == bundle
    }

    /// The work this process holds that a relaunch would lose and a daemon
    /// restart would fail mid-way — the app half of the busy guard (the
    /// daemon reports its own half on /status).
    public struct AppWork: Equatable {
        /// The dictation controller is recording or transcribing.
        public var dictating: Bool
        /// A speak request is awaiting its audio, or the audio is playing.
        public var speaking: Bool
        /// A voice design is running or its takes are under review.
        public var designing: Bool
        /// A voiceover the app follows has not reached a terminal state.
        public var followingVoiceover: Bool
        /// A meeting is being recorded: a relaunch would end it.
        public var recordingMeeting: Bool

        public init(dictating: Bool, speaking: Bool, designing: Bool, followingVoiceover: Bool, recordingMeeting: Bool = false) {
            self.dictating = dictating
            self.speaking = speaking
            self.designing = designing
            self.followingVoiceover = followingVoiceover
            self.recordingMeeting = recordingMeeting
        }

        /// True only when every lane is empty.
        public var idle: Bool { !(dictating || speaking || designing || followingVoiceover || recordingMeeting) }
    }

    /// How a kickstart command ended.
    public enum KickstartOutcome: Equatable {
        case exited(Int32)
        case couldNotStart
        /// Still running at the timeout and ended by force.
        case timedOut
    }

    /// Runs the kickstart argv without blocking the caller: the process's
    /// termination wakes the caller, a `timeout` ends a wedged launchctl, and
    /// a process that never launched is reported, never waited on.
    public static func runKickstart(argv: [String], timeout: TimeInterval = kickstartTimeout) async -> KickstartOutcome {
        switch await UpdateInstaller.runProcess(UpdateInstaller.Command(argv: argv, environment: [:]),
                                                log: nil, timeout: timeout) {
        case .success(let status): return .exited(status)
        case .failure(let error): return error is UpdateInstaller.ProcessTimedOut ? .timedOut : .couldNotStart
        }
    }

    /// One mismatch episode's bookkeeping: the disk version being chased,
    /// the kickstarts already spent on it, and what the Repair row would
    /// install.
    public struct Episode {
        /// The disk version this episode is chasing.
        public private(set) var disk: String?
        /// Kickstarts spent against `disk`.
        public private(set) var kickstarts = 0
        /// What Repair would reinstall; nil while the table offers no row.
        public private(set) var repairTarget: String?

        public init() {}

        /// One pass of the table with the episode applied and its
        /// bookkeeping updated to the answer. A changed disk version starts
        /// a fresh count; only a fired kickstart spends one — a deferral
        /// waits out the work in flight and consumes nothing; an agreeing
        /// daemon ends the count; and the Repair row stays only while the
        /// table still offers it — a disk version that moved mid-episode, or
        /// an answering daemon that turned dev, unparseable or agreeing,
        /// clears it. An unreachable daemon says nothing new: the row stays.
        mutating func decide(app: String?, disk newDisk: String?, daemon: String?,
                             serviceIdle: Bool, appIdle: Bool) -> Action {
            if newDisk != disk {
                disk = newDisk
                kickstarts = 0 // a new bundle is a new mismatch: the count starts over
                repairTarget = nil // and the old target names a version no longer on disk
            }
            let action = VersionHandshake.decide(app: app, disk: disk, daemon: daemon,
                                                 kickstarts: kickstarts,
                                                 serviceIdle: serviceIdle, appIdle: appIdle)
            switch action {
            case .kickstartDaemon:
                kickstarts += 1
                repairTarget = nil
            case .offerRepair(let target):
                repairTarget = target
            case .none:
                if VersionHandshake.agrees(daemon: daemon, disk: disk) {
                    kickstarts = 0
                }
                // A daemon that answered and still gets no action — agreeing,
                // dev or unparseable — retires the row; one that did not answer
                // says nothing new, so the row stays.
                if daemon != nil { repairTarget = nil }
            case .relaunchSelf, .deferUntilIdle:
                repairTarget = nil
            }
            return action
        }

        /// The pass as the app runs it: the latest /status answer (nil when the
        /// daemon did not answer) and the app's own work in flight. The busy
        /// guards come from here, so no caller assembles them by hand — a
        /// daemon that reports nothing counts idle, one that reports busy holds
        /// the action back.
        public mutating func decide(app: String?, disk: String?, status: DaemonStatus?, work: AppWork) -> Action {
            decide(app: app, disk: disk, daemon: status?.version,
                   serviceIdle: status?.idle ?? true, appIdle: work.idle)
        }
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
