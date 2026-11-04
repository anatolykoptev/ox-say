import AVFoundation

/// Plays a synthesized WAV through the default output; pauses and resumes in
/// place. Playing straight from memory, so there is no temp file to clean up.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    /// Called on the main queue when playback ends on its own — not after stop().
    var onFinish: (() -> Void)?

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

    /// Stops whatever was playing and starts the new clip. A player that does not start (the output device is gone)
    /// throws, so nobody tracks a clip that never sounds.
    func play(wav: Data) throws {
        stop()
        serial += 1
        let next = try AVAudioPlayer(data: wav)
        next.delegate = self
        next.prepareToPlay()
        player = next
        guard next.play() else {
            player = nil
            next.delegate = nil
            throw DidNotStart()
        }
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

    /// A clip that cannot be decoded mid-way ends like one that finished: nobody is left waiting for it.
    func audioPlayerDecodeErrorDidOccur(_ failed: AVAudioPlayer, error _: Error?) {
        audioPlayerDidFinishPlaying(failed, successfully: false)
    }

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully _: Bool) {
        guard finished === player else { return }
        player = nil
        DispatchQueue.main.async { [onFinish] in onFinish?() }
    }
}
