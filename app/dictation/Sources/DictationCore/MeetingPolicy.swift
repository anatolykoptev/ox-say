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

    public init() {}

    public mutating func failed() -> Step {
        let delay = attempts < Self.delays.count ? Self.delays[attempts] : Self.steadyDelay
        let step = Step(delay: delay, notify: attempts == 0)
        attempts += 1
        return step
    }

    /// True when this success ends a streak of failures (the recovery is told).
    public mutating func succeeded() -> Bool {
        defer { attempts = 0 }
        return attempts > 0
    }
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

    /// The call watcher runs while auto-start is on, and also while an automatic recording is running even if the
    /// user turned auto-start off meanwhile: its silence auto-stop needs the watcher.
    public static func watcherShouldRun(autoStart: Bool, recording: CallTracker.Origin?) -> Bool {
        autoStart || recording == .auto
    }

    /// A detected call: record by itself, or offer. Never by itself while an update installs (the relaunch would end it).
    public static func onCallStarted(source: String, autoStart: Bool, autoSources: Set<String>, installing: Bool) -> CallStart {
        autoStart && autoSources.contains(source) && !installing ? .start : .prompt
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
