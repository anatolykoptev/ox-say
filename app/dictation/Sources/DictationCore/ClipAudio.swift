import Foundation

/// What the player must do after a clip event, in order.
public enum ClipEffect: Equatable {
    /// Meeting audio, a voice sample and the app's own speech player stop: two streams never overlap.
    case stopOtherAudio
    case start, pause, resume
    /// The player stops and drops the clip.
    case halt
    /// A clip that sounded no longer holds the version handshake (`appWork.speaking`): it may run again.
    case handshakeMayRun
    /// A meeting recording captures the output, so the clip does not sound.
    case blockedByRecording
}

/// The sounding state of the clip on Озвучка, decided without a player so each rule can be tested. The app's source
/// executes the effects. Only a clip that actually sounds holds the handshake, so a pause (which releases it) and a
/// stop of a paused clip (which has nothing left to release) say so.
public struct ClipAudio: Equatable {
    public enum Sound: Equatable { case stopped, playing, paused }

    public private(set) var sound: Sound = .stopped

    public init() {}

    /// Holds the version handshake: the clip is `.playing` AND the player really sounds. A player that stopped without
    /// telling (`playerIsPlaying` false) never holds it, whatever was tracked.
    public func busy(playerIsPlaying: Bool) -> Bool { sound == .playing && playerIsPlaying }

    /// From the start of the clip. `recordingRunning` is read live, at the moment the clip would sound.
    public mutating func start(recordingRunning: Bool) -> [ClipEffect] {
        guard !recordingRunning else { return stop() + [.blockedByRecording] }
        sound = .playing
        return [.stopOtherAudio, .start]
    }

    /// ▶/⏸ on the clip on screen.
    public mutating func playPause(recordingRunning: Bool) -> [ClipEffect] {
        switch sound {
        case .playing:
            sound = .paused
            return [.pause, .handshakeMayRun]
        case .paused:
            guard !recordingRunning else { return stop() + [.blockedByRecording] }
            sound = .playing
            return [.stopOtherAudio, .resume]
        case .stopped:
            return start(recordingRunning: recordingRunning)
        }
    }

    public mutating func stop() -> [ClipEffect] {
        let was = sound
        sound = .stopped
        switch was {
        case .playing: return [.halt, .handshakeMayRun]
        case .paused: return [.halt]
        case .stopped: return []
        }
    }

    /// The clip ended on its own.
    public mutating func finished() -> [ClipEffect] {
        sound = .stopped
        return [.handshakeMayRun]
    }

    /// The player could not start the clip.
    public mutating func startFailed() { sound = .stopped }
}
