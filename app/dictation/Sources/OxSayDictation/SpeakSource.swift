import AppKit
import AVFoundation
import DictationCore
import MainWindowUI
import UniformTypeIdentifiers

/// The Озвучка page's glue on the fast voice: it sends the text to the daemon, keeps the session's clips, plays them
/// and carries «Сохранить…» out. What the page may show is DictationCore's (`SpeakPageState`, `SpeakControls`,
/// `SpeakInputCheck`, `ReachTracker`, `SpeakClips`); nothing is decided here beyond the order of the calls.
@MainActor
final class SpeakSource {
    /// The editor's text, kept as a view preference.
    static let draftKey = "speak.draft"

    private let model: MainWindowModel
    private let host: MainWindowHost
    private let player = AudioPlayer()
    private var request: Task<Void, Never>?
    /// A stop, a new text or a closed window moves it on, so the answer of the request they left behind is dropped
    /// (`SpeechClient` reports a cancelled request as an unreachable daemon, which must never reach the page).
    private var generation = Generation()
    private var tracker = ReachTracker()
    private var voiceChosen = false
    /// What sounds elsewhere in the app (a voice sample, meeting audio, the app's own speech player) stops before a
    /// clip sounds: two streams never overlap.
    var stopOtherAudio: () -> Void = {}
    /// The clip's sounding state; `ClipAudio` decides, `perform` carries it out.
    private var audio = ClipAudio()

    init(model: MainWindowModel, host: MainWindowHost) {
        self.model = model
        self.host = host
        model.data.speak.text = SpeakDraft.initial(stored: host.defaults.string(forKey: Self.draftKey),
                                                   firstRun: host.consumeFirstRun(), language: L10nBundle.locale.identifier)
        player.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.data.speak.playback = .stopped
                self.perform(self.audio.finished())
            }
        }
    }

    /// A request is on its way or a clip sounds: a daemon restart or an app relaunch would cut it.
    var busy: Bool { model.data.speak.phase == .generating || audio.busy }

    // MARK: window

    /// After every status read of the refresh pass: the daemon's answer (or its silence) and the studio voice's state.
    func statusRead() {
        let status = host.daemonStatus()
        record(answered: status != nil)
        model.data.speak.studio = StudioAvailability.held(previous: model.data.speak.studio, status: status, waiting: tracker.waiting)
        model.data.speak.advanced = model.advanced
    }

    private func record(answered: Bool) {
        tracker.record(answered: answered, sentence: SpeechError.daemonUnreachable("").message())
        if model.data.speak.reach != tracker.reach { model.data.speak.reach = tracker.reach }
    }

    /// The voices changed (the library was read, a voice was deleted): the first read picks the Russian read-aloud voice
    /// as the starting choice (`StudioMenu.voiceChoices`); a chosen voice that is gone falls back to the standard one.
    func voicesChanged() {
        let voices = model.data.voices.voices
        model.data.speak.voice = SpeakVoice.existing(model.data.speak.voice, in: voices)
        guard !voiceChosen, !voices.isEmpty else { return }
        voiceChosen = true
        let choices = StudioMenu.voiceChoices(voices: voices, russianPick: model.data.voices.russianVoice)
        model.data.speak.voice = choices.names[choices.selected]
    }

    func windowClosed() {
        stop()
        stopClip()
    }

    /// A meeting recording began: the output is captured, so nothing sounds.
    func recordingStarted() { stopClip() }

    // MARK: editing

    func textChanged(_ text: String) {
        host.defaults.set(text, forKey: Self.draftKey)
        // An edit makes the result on screen (or its failure) stale; the clip stays in the list.
        switch model.data.speak.phase {
        case .ready, .failed:
            model.data.speak.phase = .idle
            model.data.speak.selectedID = nil
        case .idle, .generating:
            break
        }
    }

    func newText() {
        stop()
        stopClip()
        model.data.speak.text = ""
        model.data.speak.selectedID = nil
        host.defaults.set("", forKey: Self.draftKey)
    }

    func select(_ id: String) {
        // The list is disabled while a take is made; this is the same rule for any other caller.
        guard model.data.speak.phase.allowsSelection else { return }
        guard let clip = model.data.speak.clips.first(where: { $0.id == id }) else { return }
        stop()
        stopClip()
        model.data.speak.text = clip.text
        host.defaults.set(clip.text, forKey: Self.draftKey)
        model.data.speak.voice = SpeakVoice.existing(clip.voice, in: model.data.voices.voices)
        model.data.speak.selectedID = clip.id
        model.data.speak.phase = .ready
    }

    // MARK: voicing

    /// «Озвучить», «Повторить» and (with `variant`) «Ещё вариант»: a variant is the same text on a new random seed.
    func generate(variant: Bool = false) {
        let speak = model.data.speak
        if case .generating = speak.phase { return }
        // The text goes to the daemon exactly as typed: that is what `SpeakInputCheck` counts.
        let text = speak.text
        guard SpeakInputCheck.problem(text, engine: .fast, text: { $0.text }) == nil else { return }
        if let refusal = host.speechRefusal() {
            model.data.notice = refusal
            return
        }
        stopClip()
        let seed = variant ? Int.random(in: 1...999_999_999) : nil
        let voice = speak.voice
        let language = VoicePick.languageHint(of: text).map { VoicePreview.language(locale: $0) }
        model.data.speak.phase = .generating
        let token = generation.advance()
        let speech = host.speech
        request = Task { @MainActor [weak self] in
            do {
                let wav = try await speech.speak(text, voice: voice, language: language, seed: seed)
                guard let self, self.generation.isCurrent(token) else { return }
                self.record(answered: true)
                self.finished(wav: wav, text: text, voice: voice)
            } catch {
                guard let self, self.generation.isCurrent(token) else { return }
                if case SpeechError.daemonUnreachable = error { self.record(answered: false) }
                self.model.data.speak.phase = .failed(SpeechError.plain(error))
                self.host.workEnded()
            }
        }
    }

    /// «Остановить»: the request is dropped, and the page goes back to its text.
    func stop() {
        guard case .generating = model.data.speak.phase else { return }
        generation.advance()
        request?.cancel()
        request = nil
        model.data.speak.phase = .idle
        host.workEnded()
    }

    private func finished(wav: Data, text: String, voice: String?) {
        guard let probe = try? AVAudioPlayer(data: wav) else {
            model.data.speak.phase = .failed(L10nKey.playFailed.text)
            host.workEnded()
            return
        }
        let clip = SpeakClip(id: UUID().uuidString, title: SpeakClips.title(of: text), text: text, voice: voice,
                             seconds: probe.duration, wav: wav, created: Date())
        model.data.speak.clips = SpeakClips.append(clip, to: model.data.speak.clips)
        model.data.speak.selectedID = clip.id
        model.data.speak.phase = .ready
        if !startPlaying(clip) { host.workEnded() }
    }

    // MARK: playing

    /// ▶/⏸ on the clip on screen.
    func playPause() {
        guard let clip = model.data.speak.selectedClip else { return }
        perform(audio.playPause(recordingRunning: host.meetings()?.recordingElapsed != nil), clip: clip)
    }

    @discardableResult
    private func startPlaying(_ clip: SpeakClip) -> Bool {
        perform(audio.start(recordingRunning: host.meetings()?.recordingElapsed != nil), clip: clip)
        return audio.sound == .playing
    }

    func stopClip() {
        perform(audio.stop())
        model.data.speak.playback = .stopped
    }

    /// Carries out what `ClipAudio` decided, in order.
    private func perform(_ effects: [ClipEffect], clip: SpeakClip? = nil) {
        for effect in effects {
            switch effect {
            case .stopOtherAudio:
                stopOtherAudio()
            case .start:
                guard let clip else { break }
                do {
                    try player.play(wav: clip.wav)
                    model.data.speak.playback = .playing
                } catch {
                    audio.startFailed()
                    model.data.speak.playback = .stopped
                    model.data.notice = L10nKey.playFailed.text
                    host.workEnded()
                }
            case .pause:
                player.toggle()
                model.data.speak.playback = .paused
            case .resume:
                player.toggle()
                model.data.speak.playback = .playing
            case .halt:
                player.stop()
                model.data.speak.playback = .stopped
            case .handshakeMayRun:
                host.workEnded()
            case .blockedByRecording:
                model.data.notice = L10nKey.speakPlayBlockedRecording.text
            }
        }
    }

    // MARK: saving

    /// «Сохранить…»: the save panel is a sheet on the main window; the person's own act writes the file.
    func save() {
        guard let clip = model.data.speak.selectedClip else { return }
        SpeakSave.present(clip, in: host.mainWindow()) { [weak self] saved in
            if !saved { self?.model.data.notice = L10nKey.speakSaveFailed.text }
        }
    }
}

/// The save panel of «Сохранить…». It lives apart from the source so the host can hand it over as a closure.
enum SpeakSave {
    @MainActor
    static func present(_ clip: SpeakClip, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = SpeakClips.fileName(forTitle: clip.title)
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try clip.wav.write(to: url, options: .atomic)
                completion(true)
            } catch {
                completion(false)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            panel.begin(completionHandler: write)
        }
    }
}
