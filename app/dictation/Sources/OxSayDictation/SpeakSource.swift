import AppKit
import AVFoundation
import DictationCore
import MainWindowUI
import UniformTypeIdentifiers

/// The Озвучка page's glue: on the fast voice it sends the text to the daemon, keeps the session's clips, plays them
/// and carries «Сохранить…» out; on the studio voice it starts a project, keeps the daemon's project list and plays a
/// finished track through the same player. What the page may show is DictationCore's (`SpeakPageState`, `SpeakControls`,
/// `SpeakInputCheck`, `ReachTracker`, `SpeakClips`, `SpeakList`, `SpeakStudio`); nothing is decided here beyond the order
/// of the calls.
@MainActor
final class SpeakSource {
    /// The editor's text, kept as a view preference.
    static let draftKey = "speak.draft"
    /// «Качество» as the person left it, a view preference.
    static let qualityKey = "speak.quality"
    /// Bars of the waveform.
    static let waveformBars = 96

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
    /// The voiceover the app follows, shared with the Studio menu.
    private let voiceover: VoiceoverService
    /// A project list read that lands after a newer one started is dropped.
    private var projectReads = Generation()
    /// Waveform reads: the answer for a track that is no longer on screen is dropped.
    private var waveformReads = Generation()
    /// The track whose bars are on screen or being read (id and path), so a project that finishes under the eye gets its bars once.
    private var waveformKey: String?
    /// A studio project is on its way to the daemon: «Остановить» is not offered (the answer would be dropped while the job runs).
    private var startingStudio = false
    /// Moves the playback cursor while a track sounds; nil otherwise.
    private var positionTimer: Timer?

    init(model: MainWindowModel, host: MainWindowHost) {
        self.model = model
        self.host = host
        voiceover = host.voiceover()
        model.data.speak.quality = host.defaults.string(forKey: Self.qualityKey).flatMap(SpeakEngine.init(rawValue:)) ?? .fast
        model.data.speak.text = SpeakDraft.initial(stored: host.defaults.string(forKey: Self.draftKey),
                                                   firstRun: host.consumeFirstRun(), language: L10nBundle.locale.identifier)
        player.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.data.speak.playback = .stopped
                self.perform(self.audio.finished())
            }
        }
        // The follower reports from the main actor; the observers hop there explicitly (their type is not isolated).
        voiceover.observe(
            onChange: { [weak self] in Task { @MainActor in self?.followedChanged() } },
            onFinish: { [weak self] _ in Task { @MainActor in self?.refreshProjects() } })
    }

    /// A request is on its way or a clip sounds: a daemon restart or an app relaunch would cut it.
    var busy: Bool { model.data.speak.phase == .generating || audio.busy(playerIsPlaying: player.isActivelyPlaying) }

    // MARK: window

    /// After every status read of the refresh pass: the daemon's answer (or its silence) and the studio voice's state.
    func statusRead() {
        let status = host.daemonStatus()
        record(answered: status != nil)
        model.data.speak.studio = StudioAvailability.held(previous: model.data.speak.studio, status: status, waiting: tracker.waiting)
        model.data.speak.advanced = model.advanced
        model.data.speak.serviceWaiting = voiceover.serviceWaiting || tracker.waiting
        if status != nil { refreshProjects() }
    }

    /// While the page is visible and the daemon does not answer, how long until the next read (nil when none is due).
    /// A daemon that was not up yet at first launch must not leave «unavailable» on screen until «Повторить» (#490).
    func recheckDelay(visible: Bool, section: MainSection) -> TimeInterval? {
        SpeakRecheck.delay(visible: visible, section: section, reach: tracker.reach, misses: tracker.misses)
    }

    // MARK: projects

    /// Reads the daemon's projects. The voiceover the app follows is fresher than the list and wins; a read that fails
    /// keeps the list on screen (the reach tracker, not this read, decides when the page is offline).
    func refreshProjects() {
        let token = projectReads.advance()
        let client = host.client
        Task { @MainActor [weak self] in
            guard let jobs = try? await client.voiceovers() else { return }
            guard let self, self.projectReads.isCurrent(token) else { return }
            self.apply(projects: jobs)
        }
    }

    /// The followed job moved: its row and its detail follow without waiting for the next list read.
    private func followedChanged() {
        model.data.speak.serviceWaiting = voiceover.serviceWaiting || tracker.waiting
        apply(projects: model.data.speak.projects)
    }

    private func apply(projects: [ProduceJob]) {
        model.data.speak.projects = SpeakList.overlay(projects: projects, followed: voiceover.job)
        // A project that is gone (deleted elsewhere) must not stay selected.
        if model.data.speak.selectedID != nil, model.data.speak.selectedClip == nil, model.data.speak.selectedProject == nil {
            model.data.speak.selectedID = nil
        }
        ensureWaveform()
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
        model.data.speak.phase = .idle
        model.data.speak.peaks = []
        waveformKey = nil
        host.defaults.set("", forKey: Self.draftKey)
    }

    func select(_ id: String) {
        // The list is disabled while a take is made; this is the same rule for any other caller.
        guard model.data.speak.phase.allowsSelection else { return }
        if model.data.speak.projects.contains(where: { $0.id == id }) {
            selectProject(id)
            return
        }
        guard let clip = model.data.speak.clips.first(where: { $0.id == id }) else { return }
        stop()
        stopClip()
        model.data.speak.text = clip.text
        host.defaults.set(clip.text, forKey: Self.draftKey)
        model.data.speak.voice = SpeakVoice.existing(clip.voice, in: model.data.voices.voices)
        model.data.speak.selectedID = clip.id
        model.data.speak.phase = .ready
        ensureWaveform()
    }

    /// A studio project: the editor's text and voice stay as they are for the next «Новый текст».
    private func selectProject(_ id: String) {
        stopClip()
        model.data.speak.selectedID = id
        model.data.speak.phase = .idle
        model.data.speak.trackMissing.remove(id)
        waveformKey = nil
        ensureWaveform()
    }

    func qualityChanged(_ quality: SpeakEngine) {
        host.defaults.set(quality.rawValue, forKey: Self.qualityKey)
    }

    // MARK: voicing

    /// «Озвучить», «Повторить» and (with `variant`) «Ещё вариант»: a variant is the same text on a new random seed.
    func generate(variant: Bool = false) {
        let speak = model.data.speak
        if case .generating = speak.phase { return }
        if speak.engine == .studio, !variant {
            generateStudio()
            return
        }
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

    /// The studio voice: the trimmed script becomes a project the daemon renders in the background and the app follows. The
    /// text is checked as the studio counts it (the trimmed script) and the same string is what goes out.
    private func generateStudio() {
        let speak = model.data.speak
        guard SpeakInputCheck.problem(speak.text, engine: .studio, text: { $0.text }) == nil,
              let start = SpeakStudio.start(text: speak.text) else { return }
        if let refusal = host.speechRefusal() {
            model.data.notice = refusal
            return
        }
        stopClip()
        let voice = speak.voice
        model.data.speak.phase = .generating
        startingStudio = true
        let token = generation.advance()
        let voiceover = self.voiceover
        request = Task { @MainActor [weak self] in
            do {
                let job = try await voiceover.start(script: start.script, title: start.title, voice: voice,
                                                    format: start.format, options: start.options)
                guard let self, self.generation.isCurrent(token) else { return }
                self.startingStudio = false
                self.record(answered: true)
                self.model.data.speak.projects = SpeakList.overlay(projects: self.model.data.speak.projects, followed: job)
                self.selectProject(job.id)
            } catch {
                guard let self, self.generation.isCurrent(token) else { return }
                self.startingStudio = false
                if case StudioError.daemonUnreachable = error { self.record(answered: false) }
                // A 409 (another voiceover is running) comes back in the daemon's own words.
                self.model.data.speak.phase = .failed(StudioError.plain(error))
                self.host.workEnded()
            }
        }
    }

    /// «Остановить»: the request is dropped, and the page goes back to its text.
    func stop() {
        guard case .generating = model.data.speak.phase, !startingStudio else { return }
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
        ensureWaveform()
        if !startPlaying(clip) { host.workEnded() }
    }

    // MARK: playing

    /// ▶/⏸ on the item on screen: a clip, or the track of a finished project. Both go through `ClipAudio` and `perform`.
    func playPause() {
        guard let track = selectedTrack() else { return }
        perform(audio.playPause(recordingRunning: host.meetings()?.recordingElapsed != nil), track: track)
    }

    @discardableResult
    private func startPlaying(_ clip: SpeakClip) -> Bool {
        perform(audio.start(recordingRunning: host.meetings()?.recordingElapsed != nil), track: { clip.wav })
        return audio.sound == .playing
    }

    /// The audio of what is selected, read only when a start needs it.
    private func selectedTrack() -> (() -> Data?)? {
        if let clip = model.data.speak.selectedClip { return { clip.wav } }
        guard let job = model.data.speak.selectedProject else { return nil }
        return { [weak self] in
            guard let data = Self.readTrack(of: job) else {
                self?.model.data.speak.trackMissing.insert(job.id)
                return nil
            }
            return data
        }
    }

    /// The published WAV of a finished project, mapped rather than copied: a long track is hundreds of megabytes.
    private static func readTrack(of job: ProduceJob) -> Data? {
        guard let path = job.outputPath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    func stopClip() {
        perform(audio.stop())
        model.data.speak.playback = .stopped
        model.data.speak.playedFraction = 0
    }

    /// Carries out what `ClipAudio` decided, in order. `track` supplies the audio when the effects start it.
    private func perform(_ effects: [ClipEffect], track: (() -> Data?)? = nil) {
        for effect in effects {
            switch effect {
            case .stopOtherAudio:
                stopOtherAudio()
            case .start:
                guard let wav = track?() else {
                    audio.startFailed()
                    break
                }
                do {
                    try player.play(wav: wav)
                    model.data.speak.playback = .playing
                    startPositionTicks()
                } catch {
                    audio.startFailed()
                    model.data.speak.playback = .stopped
                    model.data.notice = L10nKey.playFailed.text
                    host.workEnded()
                }
            case .pause:
                player.toggle()
                stopPositionTicks()
                model.data.speak.playback = .paused
            case .resume:
                player.toggle()
                startPositionTicks()
                model.data.speak.playback = .playing
            case .halt:
                player.stop()
                stopPositionTicks()
                model.data.speak.playedFraction = 0
                model.data.speak.playback = .stopped
            case .handshakeMayRun:
                host.workEnded()
            case .blockedByRecording:
                model.data.notice = L10nKey.speakPlayBlockedRecording.text
            }
        }
    }

    // MARK: cursor

    /// The cursor of the waveform moves only while a track sounds: the timer runs between a start (or resume) and the next
    /// pause, halt or end.
    private func startPositionTicks() {
        stopPositionTicks()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.data.speak.playedFraction = Waveform.fraction(time: self.player.currentTime, duration: self.player.duration)
            }
        }
    }

    private func stopPositionTicks() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: waveform

    /// Reads the bars of the selected track once per track (and again when a project that was running gets its file).
    /// The scan runs off the main actor; the answer of a track that is no longer selected is dropped.
    private func ensureWaveform() {
        let speak = model.data.speak
        let key: String
        let source: () -> Data?
        if let clip = speak.selectedClip {
            key = "clip:\(clip.id)"
            source = { clip.wav }
        } else if let job = speak.selectedProject, job.status == .done || job.status == .review, let path = job.outputPath {
            key = "project:\(job.id):\(path)"
            source = { try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
        } else {
            if waveformKey != nil { waveformKey = nil; model.data.speak.peaks = [] }
            return
        }
        guard key != waveformKey else { return }
        waveformKey = key
        model.data.speak.peaks = []
        model.data.speak.playedFraction = 0
        let token = waveformReads.advance()
        let id = speak.selectedID
        let bars = Self.waveformBars
        Task { @MainActor [weak self] in
            // The scan of a long track runs off the main actor.
            let peaks: [Float]? = await Task.detached(priority: .utility) { source().map { Waveform.peaks(wav: $0, bins: bars) } }.value
            guard let self, self.waveformReads.isCurrent(token) else { return }
            if let peaks { self.model.data.speak.peaks = peaks } else if let id { self.model.data.speak.trackMissing.insert(id) }
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
