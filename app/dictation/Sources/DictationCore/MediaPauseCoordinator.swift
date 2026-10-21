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
    /// No answer within the wait. The script may still be running on the
    /// player's worker: this is "unknown", not "not playing".
    case timedOut
    /// The player answered with an error, or with something unreadable.
    case unavailable

    /// The player gave no usable answer, so what it is doing is unknown.
    var isUnknown: Bool { self == .timedOut || self == .unavailable }
}

/// How long a call may wait for a player. Beginning a dictation must not hold
/// the recording back, so it asks quickly; giving the music back must outwait
/// the script's own one-second limit, or a player that is merely slow after a
/// wake or a first contact is mistaken for one that cannot be reached.
public enum MediaWait {
    case quick
    case confirming
}

/// One music player the dictation can pause. Calls block until the player
/// answers or a short timeout passes, so they belong on a background queue.
public protocol MediaPlayer: AnyObject {
    var identifier: String { get }
    func state(wait: MediaWait) -> MediaPlaybackState
    func pause()
    func play()
}

/// Decides who to pause when a dictation starts and who to resume when it ends.
/// It remembers exactly the players IT paused: a player the user had already
/// paused stays paused, and one the user started or stopped meanwhile is left be.
///
/// Not thread safe: `MediaPauseRunner` feeds it from one serial queue, in which
/// `begin` and `end` alternate (the runner queues an end before the next begin).
public final class MediaPauseCoordinator {
    private let players: [MediaPlayer]
    private let isEnabled: () -> Bool
    private let retryDelay: TimeInterval
    private let logError: (String) -> Void
    /// Player identifier → the generation that owns its resume.
    private var owner: [String: Int] = [:]
    private var deniedReported = false
    /// Fires at most once per coordinator (one per launch) when a player
    /// reports that Automation is not allowed.
    public var onPermissionDenied: (() -> Void)?

    /// `logError` receives a line without user content when a resume could not
    /// be confirmed.
    public init(players: [MediaPlayer], isEnabled: @escaping () -> Bool = { true },
                retryDelay: TimeInterval = 0.25, logError: @escaping (String) -> Void = { _ in }) {
        self.players = players
        self.isEnabled = isEnabled
        self.retryDelay = retryDelay
        self.logError = logError
    }

    /// A dictation (generation `generation`) started recording.
    public func begin(generation: Int) {
        guard isEnabled() else { return }
        for player in players {
            switch player.state(wait: .quick) {
            case .playing:
                player.pause()
                owner[player.identifier] = generation
            case .denied:
                if !deniedReported {
                    deniedReported = true
                    onPermissionDenied?()
                }
            case .paused, .notRunning, .stopped, .timedOut, .unavailable:
                break
            }
        }
    }

    /// The dictation of `generation` stopped recording (release, tap, esc,
    /// error, length cap). Gives back what it paused.
    public func end(generation: Int) {
        for player in players where owner[player.identifier] == generation {
            owner[player.identifier] = nil
            resume(player)
        }
    }

    /// Music left paused is silent and permanent, so only a positive answer
    /// that the user took over (playing, stopped) or that the player is gone
    /// skips the `play`. A player that does not answer is asked once more,
    /// then played anyway and reported.
    private func resume(_ player: MediaPlayer) {
        var state = player.state(wait: .confirming)
        if state.isUnknown {
            if retryDelay > 0 { Thread.sleep(forTimeInterval: retryDelay) }
            state = player.state(wait: .confirming)
        }
        switch state {
        case .playing, .stopped, .notRunning:
            return
        case .paused:
            player.play()
        case .denied, .timedOut, .unavailable:
            logError("\(player.identifier) resume unconfirmed (\(state)): playing anyway")
            player.play()
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
