import Foundation

/// What the app does to sound while a dictation records — the three exclusive
/// rows of the Settings → "Sound While Dictating" submenu.
public enum SoundWhileDictating: String, CaseIterable {
    /// Pause Music and Spotify — the v0.1.24 behaviour, and the default.
    case pauseMusic
    /// Fade the whole system output to a fraction of its level.
    case lowerAllSound
    /// Leave every sound alone.
    case dontTouch

    /// The menu row's localization key.
    public var titleKey: L10nKey {
        switch self {
        case .pauseMusic: return .menuSoundPauseMusic
        case .lowerAllSound: return .menuSoundLowerAll
        case .dontTouch: return .menuSoundDontTouch
        }
    }
}

/// The persisted pick, and the one-time migration off the "Pause Music While
/// Dictating" bool it replaces: an explicit off becomes "Don't Touch"; on or
/// absent — the v0.1.24 default — becomes "Pause Music". The legacy key is
/// read only on the first ask, then removed.
public enum SoundWhileDictatingSetting {
    public static let defaultsKey = "soundWhileDictating"
    /// The v0.1.24 bool, read once for migration.
    public static let legacyKey = "pauseMediaWhileDictating"

    public static func mode(_ defaults: UserDefaults) -> SoundWhileDictating {
        defer { defaults.removeObject(forKey: legacyKey) }
        if let stored = defaults.string(forKey: defaultsKey),
           let mode = SoundWhileDictating(rawValue: stored) { return mode }
        let mode: SoundWhileDictating =
            (defaults.object(forKey: legacyKey) as? Bool) == false ? .dontTouch : .pauseMusic
        defaults.set(mode.rawValue, forKey: defaultsKey)
        return mode
    }
}

/// Turns the controller's state transitions into the mode's work on a serial
/// queue: "Pause Music" pauses the players, "Lower All Sound" ducks the
/// output, "Don't Touch" does nothing — so the main thread (the hotkey)
/// never waits for a player or the audio server. The ending of a dictation
/// ends BOTH, so whatever its generation took is given back even when the
/// user picked another mode meanwhile. Call `dictationStateChanged` from the
/// main thread, once per transition.
public final class SoundWhileDictatingRunner {
    private let pause: MediaPauseCoordinator
    private let duck: VolumeDuckCoordinator?
    private let mode: () -> SoundWhileDictating
    private let queue: DispatchQueue
    private var generation = 0
    /// True from the recording's start until its end was queued.
    private var active = false

    public init(pause: MediaPauseCoordinator,
                duck: VolumeDuckCoordinator? = nil,
                mode: @escaping () -> SoundWhileDictating,
                queue: DispatchQueue = DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.media")) {
        self.pause = pause
        self.duck = duck
        self.mode = mode
        self.queue = queue
    }

    /// `.recording` starts the mode's action; anything else ends it — the
    /// release moves to `.transcribing`, a tap, an esc cancel, a start error
    /// and a failure go straight to `.idle`. Repeats are no-ops.
    public func dictationStateChanged(_ state: DictationState) {
        switch state {
        case .recording:
            guard !active else { return }
            active = true
            generation += 1
            let g = generation
            queue.async { [pause, duck, mode] in
                switch mode() {
                case .pauseMusic: pause.begin(generation: g)
                case .lowerAllSound: duck?.begin(generation: g)
                case .dontTouch: break
                }
            }
        case .transcribing, .idle:
            guard active else { return }
            active = false
            let g = generation
            queue.async { [pause, duck] in
                pause.end(generation: g)
                duck?.end(generation: g)
            }
        }
    }

    /// The launch pass for a duck this process never ended — a crash mid-
    /// dictation. Queued like the dictation work, so it cannot race it.
    public func restoreInterruptedDuck() {
        queue.async { [duck] in duck?.restoreInterruptedDuck() }
    }

    /// Waits for the queued work to finish: in tests, and to join a bounded
    /// drain that already returned.
    public func drain() { queue.sync {} }

    /// Waits at most `timeout` for the queued work — the bound the quit path
    /// needs: a hung player script or audio call must not hold termination
    /// open (a duck still unrestored keeps its marker; the next launch
    /// restores it). Returns false when the queue did not finish in time.
    @discardableResult
    public func drain(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
}
