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
    var duration: TimeInterval { player?.duration ?? 0 }
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    /// Stops whatever was playing and starts the new clip.
    func play(wav: Data) throws {
        stop()
        let next = try AVAudioPlayer(data: wav)
        next.delegate = self
        next.prepareToPlay()
        player = next
        next.play()
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

    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully _: Bool) {
        guard finished === player else { return }
        player = nil
        DispatchQueue.main.async { [onFinish] in onFinish?() }
    }
}
