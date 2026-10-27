import Foundation

/// What the app does to sound while a dictation records — the three exclusive
/// rows of the Settings → "Sound While Dictating" submenu.
public enum SoundWhileDictating: String, CaseIterable {
    /// Pause Music and Spotify — the v0.1.24 behaviour; no longer the default.
    case pauseMusic
    /// Fade the whole system output to a fraction of its level — the default.
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

/// The persisted pick, with two one-time migrations.
///
/// v0.1.24 had a "Pause Music While Dictating" bool: an explicit off becomes
/// "Don't Touch"; on or absent becomes the default. The legacy key is read on
/// the first ask, then removed.
///
/// The default is "Lower All Sound" (it covers a browser too; "Pause Music"
/// only reaches Music and Spotify). v0.1.25+ stored "pauseMusic" on the first
/// read, so a stored "pauseMusic" cannot be told from a choice. Until the
/// `defaultV2Key` marker is set it is treated as that artefact and moved to
/// "Lower All Sound", once; every `mode` read and every `choose` sets the
/// marker, so a later Pause Music pick sticks.
public enum SoundWhileDictatingSetting {
    public static let defaultsKey = "soundWhileDictating"
    /// The v0.1.24 bool, read once for migration.
    public static let legacyKey = "pauseMediaWhileDictating"
    /// Set once the stored value is a real pick, not the pre-v2 write-back.
    public static let defaultV2Key = "soundWhileDictatingDefaultV2"
    public static let defaultMode = SoundWhileDictating.lowerAllSound

    /// A user's pick. Sets the marker, so it is never migrated away.
    public static func choose(_ mode: SoundWhileDictating, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
        defaults.set(true, forKey: defaultV2Key)
    }

    public static func mode(_ defaults: UserDefaults) -> SoundWhileDictating {
        defer { defaults.removeObject(forKey: legacyKey) }
        if let stored = defaults.string(forKey: defaultsKey),
           let mode = SoundWhileDictating(rawValue: stored) {
            if mode == .pauseMusic, !defaults.bool(forKey: defaultV2Key) {
                choose(defaultMode, in: defaults)
                return defaultMode
            }
            defaults.set(true, forKey: defaultV2Key)
            return mode
        }
        let mode: SoundWhileDictating =
            (defaults.object(forKey: legacyKey) as? Bool) == false ? .dontTouch : defaultMode
        choose(mode, in: defaults)
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

    /// Waits for the queued work to finish: in tests, and to join a bounded
    /// drain that already returned.
    public func drain() { queue.sync {} }

    /// Waits at most `timeout` for the queued work — the bound the quit path
    /// needs: a hung player script or audio call must not hold termination
    /// open (a duck it did not finish stays quiet until the user raises
    /// the volume). Returns false when the queue did not finish in time.
    @discardableResult
    public func drain(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
}
