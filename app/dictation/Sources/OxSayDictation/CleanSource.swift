import AppKit
import AVFoundation
import DictationCore
import MainWindowUI
import UniformTypeIdentifiers

/// Where the cleaned copy goes: the save panel's inputs. The panel offers only the kinds the daemon writes for this file.
struct CleanOutputRequest {
    var directory: URL
    var name: String
    var extensions: [String]
}

/// The cleanup bar's glue: it measures a picked file, runs the save panel, builds the daemon call for `CleanSession` (which
/// decides everything), plays the two files against each other and copies the session into the window's values. No decision
/// lives here beyond what the system forces, so the behaviour is in DictationCore.
///
/// A job outlives the window, like an upload: closing the window stops the sound, never the job.
@MainActor
final class CleanSource {
    private let model: MainWindowModel
    private let host: MainWindowHost
    private let session: CleanSession
    private let player = CleanPlayer()
    /// The state the window last saw, to notice when a finished job is closed or replaced.
    private var shownDone: CleanDone?
    /// Stops whatever else sounds in the window (a meeting, a voice sample, a voiceover); the window wires it.
    var stopOtherAudio: () -> Void = {}
    /// The status was re-read because of a failure: the window reschedules its polling (a model download starts one).
    var statusRefreshed: () -> Void = {}
    private var lastFailure: String?

    init(model: MainWindowModel, host: MainWindowHost) {
        self.model = model
        self.host = host
        let client = host.client
        session = CleanSession(ops: CleanOps(
            clean: { input, output, overwrite, seconds in
                try await client.cleanVoice(input: input, output: output, overwrite: overwrite,
                                            timeout: StudioClient.cleanTimeout(forSeconds: seconds))
            },
            duration: { url in
                let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
                return seconds?.isFinite == true ? seconds : nil
            }))
        session.onChange = { [weak self] in self?.sync() }
        player.onChange = { [weak self] position, duration, ended in self?.playerReported(position: position, duration: duration, ended: ended) }
        player.onFailure = { [weak self] in
            self?.model.data.clean.playback.isPlaying = false
            self?.model.data.notice = L10nKey.playFailed.text
        }
    }

    /// A cleanup is on its way: the version handshake waits for it.
    var working: Bool { session.isWorking }

    /// The daemon's /status was read: the bar offers the button, or says why it cannot.
    func statusRead() { session.statusRead(host.daemonStatus()) }

    /// While the model downloads the window reads the status every few seconds, so the button comes back by itself.
    func recheckDelay(visible: Bool) -> TimeInterval? {
        visible && session.status?.voiceClean?.installing == true ? 5 : nil
    }

    private func sync() {
        let state = session.state
        // A finished job that was closed, or replaced by a new one, stops its sound and forgets its position.
        let done: CleanDone? = { if case .done(let d) = state { return d } else { return nil } }()
        if done != shownDone {
            player.stop()
            model.data.clean.playback = CleanPlayback()
            shownDone = done
        }
        model.data.clean.state = state
        // A new failure may be "the model is downloading": read the status once, so the bar says so and offers no button.
        let failed: String? = { if case .failed(let sentence) = state { return sentence } else { return nil } }()
        if failed != lastFailure {
            lastFailure = failed
            if failed != nil {
                Task { @MainActor [weak self] in
                    await self?.host.refreshStatus()
                    self?.statusRead()
                    self?.statusRefreshed()
                }
            }
        }
    }

    /// A file picked or dropped on the bar: asks where the copy goes, then cleans. Everything that can go wrong before the
    /// request is said in the window's notice; the daemon's refusals come back through the session.
    func pick(_ url: URL) {
        if let sentence = CleanFileCheck.problem(ext: url.pathExtension) {
            model.data.notice = sentence
            return
        }
        guard !session.isWorking else {
            model.data.notice = CleanProblem.busy.sentence()
            return
        }
        Task { @MainActor in
            let picture = CleanNaming.hasPicture(url, measured: await Self.hasPicture(url))
            let request = CleanOutputRequest(directory: url.deletingLastPathComponent(),
                                             name: CleanNaming.defaultOutput(for: url, picture: picture),
                                             extensions: CleanNaming.outputExtensions(picture: picture))
            host.chooseCleanOutput(request) { [weak self] output in
                guard let self, let output else { return }
                // The panel has already asked about replacing a file that exists; that answer is the consent.
                if let sentence = self.session.start(input: url, output: output, overwrite: FileManager.default.fileExists(atPath: output.path)) {
                    self.model.data.notice = sentence
                }
            }
        }
    }

    /// Whether the file has a picture; nil when it cannot be told (the name decides then).
    private static func hasPicture(_ url: URL) async -> Bool? {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video) else { return nil }
        return !tracks.isEmpty
    }

    func cancel() { session.cancel() }

    func dismiss() { session.dismiss() }

    /// «Показать в Finder»: the cleaned file selected in a Finder window.
    func reveal() {
        guard case .done(let done) = session.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([done.url(for: .cleaned)])
    }

    // MARK: listening

    func playPause() {
        guard case .done(let done) = session.state else { return }
        apply(model.data.clean.playback.toggle(loaded: player.isLoaded), done: done)
    }

    func choose(_ side: CleanSide) {
        guard case .done(let done) = session.state, let effect = model.data.clean.playback.choose(side) else { return }
        apply(effect, done: done)
    }

    func seek(_ seconds: Double) {
        guard case .done(let done) = session.state else { return }
        apply(model.data.clean.playback.seek(to: seconds), done: done)
    }

    /// The window closed, or other audio started: the comparison stops where it is.
    func stopPlayback() {
        player.stop()
        model.data.clean.playback.isPlaying = false
    }

    private func apply(_ effect: CleanPlayback.Effect, done: CleanDone) {
        switch effect {
        case .load(let side, let position, let play):
            // Whatever else sounds stops first, as it does for every player in the window.
            if play { stopOtherAudio() }
            player.load(done.url(for: side), at: position, play: play)
        case .play:
            stopOtherAudio()
            player.resume()
        case .pause:
            player.pause()
        case .seek(let seconds):
            if player.isLoaded { player.seek(to: seconds) } else { player.load(done.url(for: model.data.clean.playback.side), at: seconds, play: false) }
        }
    }

    /// The player reports four times a second and the clock shows whole seconds: a tick inside the same second changes
    /// nothing on screen, and publishing it would redraw the whole window.
    private func playerReported(position: Double, duration: Double?, ended: Bool) {
        let shown = model.data.clean.playback
        guard ended || Int(position) != Int(shown.position) || (duration != nil && duration != shown.duration) else { return }
        model.data.clean.playback.tick(position: position, duration: duration)
        if ended { model.data.clean.playback.ended() }
    }
}

/// The save panel of the cleanup bar, a sheet on the main window: where the cleaned copy goes. Only the person's own choice
/// names the file, and only the kinds the daemon writes for it are offered.
enum CleanOutputPanel {
    @MainActor
    static func present(_ request: CleanOutputRequest, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = request.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = request.name
        panel.directoryURL = request.directory
        panel.message = L10nKey.cleanPanelMessage.text
        panel.prompt = L10nKey.cleanPanelPrompt.text
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in completion(response == .OK ? panel.url : nil) }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// Plays one file of the comparison through the default output. One `AVPlayer`, whose item is replaced when the side
/// changes, so the position carries over. It stands apart from dictation like the meeting player: nothing here starts or
/// pauses a dictation.
@MainActor
final class CleanPlayer {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// Position, duration once known, and whether the file played to its end.
    var onChange: ((Double, Double?, Bool) -> Void)?
    var onFailure: (() -> Void)?

    var isLoaded: Bool { player != nil }

    /// Plays `url` from `seconds` (or holds there), replacing whatever was loaded.
    func load(_ url: URL, at seconds: Double, play: Bool) {
        stop()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard self?.player?.currentItem === item else { return }
                self?.stop()
                self?.onFailure?()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.player?.currentItem === item else { return }
                self?.stop()
                self?.onChange?(0, nil, true)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                if play { player.play() }
                self.report()
            }
        }
    }

    func resume() { player?.play() }

    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Stops and lets go of everything; safe when nothing plays.
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
    }

    private func report() {
        guard let player else { return }
        let duration = player.currentItem.map { $0.duration.seconds }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let now = player.currentTime().seconds
        onChange?(now.isFinite ? now : 0, duration, false)
    }
}
