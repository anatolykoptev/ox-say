import AVFoundation
import DictationCore
import MainWindowUI

/// Plays one meeting's audio for the main window's mini player. The daemon serves it as a WAV over loopback
/// (`GET /v1/meetings/{id}/audio`, Range supported) and asks for no token, so the asset is the plain URL: no header,
/// no resource-loader delegate, nothing secret to leak into a log. It stands apart from dictation on purpose: no code
/// path leads from this player into the dictation, or back (no media-pause call, no sound-setting read), so playing
/// never starts a dictation and dictation never pauses or stops it. "Lower All Sound" lowers the whole system output
/// while a dictation runs, so a meeting that plays then is quieter too; that is the setting the user chose.
@MainActor
final class MeetingAudioPlayer {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var meetingID: String?
    /// What the window was last told: a tick that changes nothing visible is not published.
    private var published: PlaybackValues?

    /// The mini player's values; nil when nothing plays.
    var onChange: ((PlaybackValues?) -> Void)?
    /// The item could not be played (the daemon went away mid-way, the file broke).
    var onFailure: (() -> Void)?

    var isActive: Bool { player != nil }
    var activeMeeting: String? { meetingID }

    /// Starts `url` at `seconds` into the recording, replacing whatever plays.
    func play(url: URL, meetingID: String, from seconds: TimeInterval) {
        stop()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.meetingID = meetingID
        published = nil
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.failed(item) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            // The end of an item that was already replaced is not the end of this one.
            Task { @MainActor in
                guard self?.player?.currentItem === item else { return }
                self?.stop()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        report()
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                player.play()
                self.report()
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        report()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        report()
    }

    /// Stops and lets go of everything; safe to call when nothing plays.
    func stop() {
        guard let player else { return }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        self.player = nil
        meetingID = nil
        published = nil
        onChange?(nil)
    }

    private func failed(_ item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        stop()
        onFailure?()
    }

    private func report() {
        guard let player, let meetingID else { return }
        let duration = player.currentItem.map { $0.duration.seconds }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let now = player.currentTime().seconds
        let values = PlaybackValues(meetingID: meetingID, isPlaying: player.timeControlStatus != .paused,
                                    position: max(0, now.isFinite ? now : 0), duration: duration)
        guard values.publishes(after: published) else { return }
        published = values
        onChange?(values)
    }
}
