import Foundation

/// What a media player says about itself when asked, without being launched.
public enum MediaPlaybackState: Equatable {
    /// Not running: never addressed, never launched.
    case notRunning
    case playing
    case paused
    case stopped
    /// The user has not allowed (or has revoked) Automation for this player.
    case denied
    /// The answer did not come: a timeout, the app quit meanwhile, an error.
    case unavailable
}

/// One music player the dictation can pause. Calls block until the player
/// answers or a short timeout passes, so they belong on a background queue.
public protocol MediaPlayer: AnyObject {
    var identifier: String { get }
    func state() -> MediaPlaybackState
    func pause()
    func play()
}

/// Decides who to pause when a dictation starts and who to resume when it ends.
/// It remembers exactly the players IT paused, per dictation generation: a
/// player the user had already paused stays paused, and a second dictation
/// starting before the first one's resume ran takes over the first's players
/// instead of pausing them twice or leaving them to be resumed mid-sentence.
///
/// Not thread safe: `MediaPauseRunner` feeds it from one serial queue.
public final class MediaPauseCoordinator {
    private let players: [MediaPlayer]
    private let isEnabled: () -> Bool
    /// Player identifier → the generation that owns its resume.
    private var owner: [String: Int] = [:]
    private var deniedReported = false
    /// Fires at most once per coordinator (one per launch) when a player
    /// reports that Automation is not allowed.
    public var onPermissionDenied: (() -> Void)?

    public init(players: [MediaPlayer], isEnabled: @escaping () -> Bool = { true }) {
        self.players = players
        self.isEnabled = isEnabled
    }

    /// A dictation (generation `generation`) started recording.
    public func begin(generation: Int) {
        guard isEnabled() else { return }
        for player in players {
            switch player.state() {
            case .playing:
                player.pause()
                owner[player.identifier] = generation
            case .paused:
                // Paused by an earlier dictation whose resume has not run yet:
                // this dictation now owns it. Paused by the user: not ours.
                if owner[player.identifier] != nil { owner[player.identifier] = generation }
            case .denied:
                if !deniedReported {
                    deniedReported = true
                    onPermissionDenied?()
                }
            case .notRunning, .stopped, .unavailable:
                break
            }
        }
    }

    /// The dictation of `generation` stopped recording (release, tap, esc,
    /// error, length cap). Resumes only what it paused, and only if the player
    /// is still paused — one the user started or stopped meanwhile is left be.
    public func end(generation: Int) {
        for player in players where owner[player.identifier] == generation {
            owner[player.identifier] = nil
            if player.state() == .paused { player.play() }
        }
    }
}

/// Turns the controller's state transitions into `begin`/`end` calls on a
/// serial queue, so the main thread (the hotkey) never waits for a player.
/// Call `dictationStateChanged` from the main thread, once per transition.
public final class MediaPauseRunner {
    private let coordinator: MediaPauseCoordinator
    private let queue: DispatchQueue
    private var generation = 0
    /// True from the recording's start until its end was queued.
    private var active = false

    public init(coordinator: MediaPauseCoordinator,
                queue: DispatchQueue = DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.media")) {
        self.coordinator = coordinator
        self.queue = queue
    }

    /// `.recording` pauses; anything else ends the recording and resumes — the
    /// release moves to `.transcribing`, a tap, an esc cancel, a start error
    /// and a failure go straight to `.idle`. Repeats are no-ops.
    public func dictationStateChanged(_ state: DictationState) {
        switch state {
        case .recording:
            guard !active else { return }
            active = true
            generation += 1
            let g = generation
            queue.async { [coordinator] in coordinator.begin(generation: g) }
        case .transcribing, .idle:
            guard active else { return }
            active = false
            let g = generation
            queue.async { [coordinator] in coordinator.end(generation: g) }
        }
    }

    /// Waits for the queued pauses and resumes to finish: at quit, so music
    /// paused for a dictation is not left paused, and in tests.
    public func drain() { queue.sync {} }
}

/// The "Pause Music While Dictating" menu setting.
public enum MediaPauseSetting {
    public static let defaultsKey = "pauseMediaWhileDictating"

    /// On unless the user turned it off.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}
