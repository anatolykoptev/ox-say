import AVFoundation

/// Plays a synthesized WAV through the default output; pauses and resumes in
/// place. Playing straight from memory, so there is no temp file to clean up.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    /// Called on the main queue when playback ends on its own — not after stop().
    var onFinish: (() -> Void)?
    /// Like `onFinish`, and told whether the clip played to its end: false when it could not be decoded. Only the Озвучка
    /// page asks; the other users of the player end a failed clip silently, as before.
    var onEnd: ((_ successfully: Bool) -> Void)?

    /// True while a paused clip is held; false while playing or when nothing
    /// is loaded.
    var isPaused: Bool { player != nil && !(player?.isPlaying ?? false) }
    /// True while a clip is actually sounding (not paused, not finished).
    var isActivelyPlaying: Bool { player?.isPlaying ?? false }
    var duration: TimeInterval { player?.duration ?? 0 }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    /// Counts the clips started: whoever started one can tell later whether it is still the last (VariantPlayback).
    private(set) var serial = 0

    struct DidNotStart: Error {}

    /// A clip decoded and ready to sound, held until `playPrepared` or the next `prepare`.
    private var prepared: AVAudioPlayer?

    /// Decodes the clip without touching what plays now, so a caller can find out that it cannot sound BEFORE it stops
    /// anything else. Throws when the data cannot be decoded or the output cannot take it.
    func prepare(wav: Data) throws {
        prepared = nil
        let next = try AVAudioPlayer(data: wav)
        next.delegate = self
        guard next.prepareToPlay() else {
            next.delegate = nil
            throw DidNotStart()
        }
        prepared = next
    }

    /// Stops whatever was playing and starts the clip `prepare` made. A player that does not start (the output device is
    /// gone) throws, so nobody tracks a clip that never sounds.
    func playPrepared() throws {
        stop()
        guard let next = prepared else { throw DidNotStart() }
        prepared = nil
        player = next
        guard next.play() else {
            player = nil
            next.delegate = nil
            throw DidNotStart()
        }
        serial += 1
    }

    /// Stops whatever was playing and starts the new clip.
    func play(wav: Data) throws {
        try prepare(wav: wav)
        try playPrepared()
    }

    /// Toggles between pause and resume; a no-op when nothing is loaded.
    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Stops without firing onFinish — a superseded request or the stop button.
    func stop() {
        let previous = player
        player = nil
        previous?.delegate = nil
        previous?.stop()
    }

    /// A clip that cannot be decoded mid-way ends like one that finished (nobody is left waiting for it), and says it failed.
    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error _: Error?) {
        audioPlayerDidFinishPlaying(failed, successfully: false)
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully: Bool) {
        guard finished === player else { return }
        player = nil
        DispatchQueue.main.async { [onFinish, onEnd] in
            onEnd?(successfully)
            onFinish?()
        }
    }
}
