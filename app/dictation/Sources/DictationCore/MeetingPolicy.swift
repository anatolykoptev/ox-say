import Foundation

/// One tick of the recording (every 0.25 s) turned into what the controller must do: stop, or tell the user.
/// Everything decidable is here, where the shim tests it; the controller only carries the actions out.
public struct RecordingMonitor {
    public enum Stop: Equatable { case diskFull, cap }
    public enum Say: Hashable { case tapSilent, noSystemAudio }
    public enum Action: Equatable {
        case stop(Stop)
        case say(Say)
    }

    public struct Tick {
        public var elapsed: TimeInterval
        public var writeFailed: Bool
        public var callbacks: Int
        public var peak: Float
        public var playingFor: TimeInterval
        public var heardLoud: Bool
        /// The microphone channel is loud right now.
        public var meLoud: Bool
        /// Seconds since the previous tick.
        public var dt: TimeInterval

        public init(elapsed: TimeInterval, writeFailed: Bool, callbacks: Int, peak: Float, playingFor: TimeInterval,
                    heardLoud: Bool, meLoud: Bool, dt: TimeInterval) {
            self.elapsed = elapsed
            self.writeFailed = writeFailed
            self.callbacks = callbacks
            self.peak = peak
            self.playingFor = playingFor
            self.heardLoud = heardLoud
            self.meLoud = meLoud
            self.dt = dt
        }
    }

    /// The tap failed to start or to restart (the controller sets it, and clears it on a recovery): "nothing recorded"
    /// would only repeat it.
    public var systemAudioFailed = false
    private var told: Set<Say> = []
    private var micLoud: TimeInterval = 0

    public init() {}

    public mutating func observe(_ t: Tick) -> [Action] {
        // The first failed write stops the recording: the rest would be a file with holes (#247).
        if t.writeFailed { return [.stop(.diskFull)] }
        if MeetingLimits.reachedCap(elapsed: t.elapsed) { return [.stop(.cap)] }
        if t.meLoud { micLoud += t.dt }
        let verdict = SystemAudioGuard.assess(.init(callbacks: t.callbacks, peak: t.peak, elapsed: t.elapsed, playingFor: t.playingFor,
                                                    heardLoud: t.heardLoud, micLoudFor: micLoud))
        switch verdict {
        case .silentTap:
            return told.insert(.tapSilent).inserted ? [.say(.tapSilent)] : []
        case .noCallbacks:
            return !systemAudioFailed && told.insert(.noSystemAudio).inserted ? [.say(.noSystemAudio)] : []
        case .otherSideQuiet:
            return !told.contains(.tapSilent) && told.insert(.noSystemAudio).inserted ? [.say(.noSystemAudio)] : []
        case .waiting, .fine:
            return []
        }
    }
}

/// When to try again after a source (the tap, the microphone) could not be restarted: 0.4, 1, 2, 4 s, then every 5 s
/// for as long as the recording runs. The first failure of a streak is told to the user, the retries are silent, and
/// the recovery is told, so a later failure is told again.
public struct Reacquire {
    public static let delays: [TimeInterval] = [0.4, 1, 2, 4]
    public static let steadyDelay: TimeInterval = 5

    public struct Step: Equatable {
        public var delay: TimeInterval
        public var notify: Bool
    }

    private var attempts = 0
    private var told = false

    /// Failures in the current streak (0 after a success).
    public var failures: Int { attempts }

    public init() {}

    /// `sourceLost`: false when the failed restart left the old source recording (a tap rebuild that failed while the
    /// old tap goes on). That failure is retried but not told, and a streak that was never told has no recovery to tell.
    public mutating func failed(sourceLost: Bool = true) -> Step {
        let delay = attempts < Self.delays.count ? Self.delays[attempts] : Self.steadyDelay
        let step = Step(delay: delay, notify: sourceLost && !told)
        told = told || step.notify
        attempts += 1
        return step
    }

    /// True when this success ends a streak of failures that was told (the recovery is told).
    public mutating func succeeded() -> Bool {
        defer { attempts = 0; told = false }
        return told
    }
}

/// Whether a failed tap rebuild means the system audio is lost (#266). The old tap is only a source while it DELIVERS:
/// after an output switch it stays as an object but may be silent, and the far side then lands in the file as padding.
/// So a failed rebuild is told when no tap exists, when the tap has delivered no buffer for `silentAfter`, or when
/// `failuresBeforeTelling` rebuilds in a row failed whatever the old tap does.
public enum TapLoss {
    /// A running tap delivers a buffer every ~10 ms (zeros included), so 3 s without one is a dead tap and, at 16 kHz,
    /// a 3 s hole in the far side: long enough to ignore a device settling, short enough to say it during the call.
    public static let silentAfter: TimeInterval = 3
    /// Failures land at 0, 0.4, 1.4, 3.4 and 7.4 s of a streak (`Reacquire` delays). A silent old tap is told at the
    /// fourth (3.4 s, past `silentAfter`); this backstop is the fifth, 7.4 s in, for an old tap that keeps handing
    /// out buffers (zeros from a device that is gone count as buffers) while the rebuild never succeeds: a device that
    /// has not come back after seven seconds is not settling.
    public static let failuresBeforeTelling = 5

    /// Seconds between the last buffer and now, from two readings of a MONOTONIC clock in nanoseconds (the recorder
    /// uses `DispatchTime.uptimeNanoseconds`): a wall-clock step (NTP, a manual change) cannot make a live tap look
    /// silent or a dead one look alive. nil when no buffer has arrived; a reading that went backwards counts as 0.
    public static func silence(lastNanos: UInt64?, nowNanos: UInt64) -> TimeInterval? {
        guard let lastNanos else { return nil }
        return nowNanos >= lastNanos ? Double(nowNanos - lastNanos) / 1e9 : 0
    }

    /// `sinceLastBuffer`: seconds since the running tap last delivered a buffer, nil when it never has. A nil counts as
    /// lost at once: a rebuild that fails before the first buffer of the recording was ever delivered is told
    /// without waiting. That window is the first milliseconds of a recording (the tap delivers every ~10 ms), so the
    /// behaviour is kept.
    /// `consecutiveFailures`: failed rebuilds in this streak, the one being judged included.
    public static func isLost(hasTap: Bool, sinceLastBuffer: TimeInterval?, consecutiveFailures: Int) -> Bool {
        guard hasTap else { return true }
        if consecutiveFailures >= failuresBeforeTelling { return true }
        guard let silent = sinceLastBuffer else { return true }
        return silent >= silentAfter
    }
}

/// A counter that tells whether an answer belongs to the recording that asked: a completion that arrives after the
/// recording ended (or after another began) is stale and is dropped (#266).
public struct Generation {
    public private(set) var value = 0
    public init() {}
    @discardableResult
    public mutating func advance() -> Int { value += 1; return value }
    public func isCurrent(_ token: Int) -> Bool { token == value }
}

/// Install a tap on an engine's input bus, start the engine. AVAudioEngine raises an uncatchable exception when a tap
/// is installed on a bus that already has one, so a leftover is removed first and a failed start removes its own.
public enum EngineStart {
    public static func start(removeTap: () -> Void, installTap: () -> Void, start: () throws -> Void) throws {
        removeTap()
        installTap()
        do {
            try start()
        } catch {
            removeTap()
            throw error
        }
    }
}

public enum Retry {
    /// `body` up to `attempts` times, `wait` between them; the first non-nil answer.
    public static func firstNonNil<T>(attempts: Int, wait: () -> Void, _ body: () -> T?) -> T? {
        for i in 0..<max(1, attempts) {
            if let value = body() { return value }
            if i < attempts - 1 { wait() }
        }
        return nil
    }
}

/// Start and watcher decisions of the controller.
public enum MeetingPolicy {
    /// `ignore`: the user said "don't record" for this app; nothing is started and nothing is offered.
    public enum CallStart: Equatable { case start, prompt, ignore }
    public enum ManualStart: Equatable { case go, waitForInstall }

    /// The call watcher runs while the global mode is not `off`, and also while an automatic recording is
    /// running even if the user turned calls off meanwhile: its silence auto-stop needs the watcher.
    public static func watcherShouldRun(mode: CallGlobalMode, recording: CallTracker.Origin?) -> Bool {
        mode != .off || recording?.endsWithTheCall == true
    }

    public static func manualStart(installing: Bool) -> ManualStart { installing ? .waitForInstall : .go }
}

/// What to do with a meeting the daemon lists at launch (or when the notes model arrives).
public enum Reconcile {
    public enum Action: Equatable { case skip, track, retryNotesThenTrack }

    public static func action(for info: MeetingInfo, exported: Set<String>, notesAvailable: Bool, currentID: String?) -> Action {
        switch info.status {
        case .recording:
            // The app died while recording: the daemon finishes the orphan; follow it so the export happens now.
            // Never the one this session is recording.
            return info.id != currentID ? .track : .skip
        case .queued, .transcribing, .summarizing:
            return .track
        case .done:
            return exported.contains(info.id) ? .skip : .track
        case .transcribed:
            if info.notesPending == "model_missing" { return notesAvailable ? .retryNotesThenTrack : .skip }
            return exported.contains(info.id) ? .skip : .track
        case .failed:
            return .skip
        case .unknown:
            // A newer daemon's state: touch nothing the app cannot classify; a later launch sees it settled.
            return .skip
        }
    }
}

/// The menu-bar icon: red while a meeting OR a dictation records, from both states in one place.
public enum StatusIconStyle {
    public struct Style: Equatable {
        public var symbol: String
        public var red: Bool
    }

    public static func style(meetingRecording: Bool, dictationRecording: Bool, dictationSymbol: String) -> Style {
        Style(symbol: meetingRecording ? "record.circle.fill" : dictationSymbol, red: dictationRecording || meetingRecording)
    }
}
