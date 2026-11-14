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
    /// The flag belongs to its request, so a superseded one never leaves it set.
    private var studioStart = StartingGate()
    private var startingStudio: Bool { studioStart.isActive(in: generation) }
    /// Phrase reads: a read that lands after a newer one started is dropped.
    private var phraseReads = Generation()
    /// The track whose phrases are on screen or being read; a re-render rewrites the file, which changes the key.
    private var phrasesKey: String?
    /// The scan of the waveform that is being read, cancelled when the selection moves on.
    private var waveformTask: Task<Void, Never>?
    /// Moves the playback cursor while a track sounds; nil otherwise.
    private var positionTimer: Timer?

    init(model: MainWindowModel, host: MainWindowHost) {
        self.model = model
        self.host = host
        voiceover = host.voiceover()
        model.data.speak.quality = host.defaults.string(forKey: Self.qualityKey).flatMap(SpeakEngine.init(rawValue:)) ?? .fast
        model.data.speak.panel = VoicePanelSettings.load(from: host.defaults)
        model.data.speak.text = SpeakDraft.initial(stored: host.defaults.string(forKey: Self.draftKey),
                                                   firstRun: host.consumeFirstRun(), language: L10nBundle.locale.identifier)
        player.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.data.speak.playback = .stopped
                self.model.data.speak.playingPhrase = nil
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

    var reach: DaemonReach { tracker.reach }

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
            // A finished job's follower copy is older than the daemon's entry; only a working one is fresher than the read.
            self.show(SpeakList.afterRead(projects: jobs, followed: self.voiceover.job))
        }
    }

    /// The followed job moved: its row and its detail follow without waiting for the next list read.
    private func followedChanged() {
        model.data.speak.serviceWaiting = voiceover.serviceWaiting || tracker.waiting
        show(SpeakList.overlay(projects: model.data.speak.projects, followed: voiceover.job))
    }

    private func show(_ projects: [ProduceJob]) {
        model.data.speak.projects = projects
        // A project that is gone (deleted elsewhere) must not stay selected, and its track must not keep sounding.
        if !SpeakList.stillPresent(model.data.speak.selectedID, projects: projects, clips: model.data.speak.clips) {
            stopClip()
            model.data.speak.selectedID = nil
        }
        adoptFreshTarget()
        resolvePendingProject(in: projects)
        ensureWaveform()
        ensurePhrases()
    }

    /// Points the page at a voiceover the route names (a notification's click, the last run's open project). A project the list
    /// does not have yet waits for it; one the list lacks (deleted since) is dropped, as `MainRoute.pruned` drops a meeting.
    func openProject(_ id: String) {
        guard !id.isEmpty else { return }
        model.data.speak.pendingProjectID = id
        resolvePendingProject(in: model.data.speak.projects)
    }

    /// Opens a voiceover a notification or the menu names. The cached list is not asked whether it exists (it predates a project
    /// that just finished); the daemon is, by id (`SpeakTarget`). Found: it joins the list and opens, as soon as a take being made
    /// allows. Not found: it is dropped and the selection stays.
    func showProject(_ id: String) {
        guard !id.isEmpty else { return }
        model.data.speak.pendingProjectID = id
        fetchingID = id
        let cached = model.data.speak.projects
        let client = host.client
        Task { @MainActor [weak self] in
            let outcome = await SpeakTarget.resolve(id: id, cached: cached, fetch: { try await client.voiceover(id: $0) })
            if self?.fetchingID == id { self?.fetchingID = nil }
            // Another target (or the same one opened meanwhile) took over while the daemon answered.
            guard let self, self.model.data.speak.pendingProjectID == id else { return }
            switch outcome {
            case .cached: self.resolvePendingProject(in: self.model.data.speak.projects)
            case .fetched(let job):
                self.freshTarget = job
                self.adoptFreshTarget()
            case .gone: self.model.data.speak.pendingProjectID = nil
            }
        }
    }

    /// The daemon's answer for the target waits here while a take is being made; the next list change opens it.
    private var freshTarget: ProduceJob?
    /// The id the daemon is being asked about: a list read that lands meanwhile must not prune it.
    private var fetchingID: String?

    private func adoptFreshTarget() {
        guard let job = freshTarget else { return }
        guard model.data.speak.pendingProjectID == job.id else { freshTarget = nil; return }
        guard model.section == .speak, model.data.speak.phase.allowsSelection else { return }
        freshTarget = nil
        model.data.speak.pendingProjectID = nil
        model.data.speak.projects = SpeakList.overlay(projects: model.data.speak.projects, followed: job)
        selectProject(job.id)
    }

    private func resolvePendingProject(in projects: [ProduceJob]) {
        guard let id = model.data.speak.pendingProjectID, freshTarget?.id != id, fetchingID != id else { return }
        let route = MainRoute(section: .speak, speakID: id).pruned(knownSpeakIDs: projects.map(\.id))
        guard let known = route.speakID else {
            model.data.speak.pendingProjectID = nil
            return
        }
        // Not on Озвучка (a restored route) or a take being made: the choice waits; the next list read asks again.
        guard projects.contains(where: { $0.id == known }), model.section == .speak, model.data.speak.phase.allowsSelection else { return }
        model.data.speak.pendingProjectID = nil
        selectProject(known)
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
        // A studio project that is still on its way keeps running in the daemon; its answer is dropped here (the list shows
        // the project once it exists) and the editor is free at once.
        if startingStudio {
            generation.advance()
            studioStart.end()
            host.workEnded()
        }
        stopClip()
        model.data.speak.text = ""
        model.data.speak.selectedID = nil
        model.data.speak.phase = .idle
        endReel()
        cancelWaveform()
        host.defaults.set("", forKey: Self.draftKey)
    }

    /// A reel is a draft, not a setting: leaving it drops the preset and puts «Качество» back to what the person saved.
    private func endReel() {
        guard model.data.speak.reel else { return }
        model.data.speak.reel = false
        model.data.speak.quality = host.defaults.string(forKey: Self.qualityKey).flatMap(SpeakEngine.init(rawValue:)) ?? .fast
    }

    /// «Новый ролик»: a new draft that is a short video; «Озвучить» sends the Reels preset. It only exists on the studio
    /// voice, so the page switches «Качество» to it (the button is drawn only where the studio voice can run).
    func newReel() {
        guard model.data.speak.studio == .available else { return }
        newText()
        model.data.speak.reel = true
        // The switch to the studio voice belongs to this draft; it is not saved as the person's «Качество».
        model.data.speak.quality = .studio
    }

    /// «Оставить только начало» under the editor: the text that fits, ending where a paragraph or sentence ends.
    func keepFirstPart() {
        let text = ScriptLimit.keepFirstPart(model.data.speak.text)
        model.data.speak.text = text
        textChanged(text)
    }

    /// «Открыть документ…»: the picked file becomes the editor's text. Over the cap the page offers to keep the first part;
    /// a file that gives no text, or cannot be read, says why in the notice and leaves the text as it was.
    func openDocument(_ url: URL) {
        guard !model.data.speak.reading, model.data.speak.phase.allowsSelection else { return }
        model.data.speak.reading = true
        // A file chosen in the importer is a security-scoped URL; the access lasts as long as the read.
        let scoped = url.startAccessingSecurityScopedResource()
        Task { @MainActor [weak self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let read = try await DocumentReader.readScript(url)
                guard let self else { return }
                self.model.data.speak.reading = false
                if read.script.isEmpty {
                    self.model.data.notice = read.emptyMessage()
                    return
                }
                self.stop()
                self.stopClip()
                self.model.data.speak.selectedID = nil
                self.model.data.speak.phase = .idle
                self.cancelWaveform()
                self.model.data.speak.text = read.script
                self.host.defaults.set(read.script, forKey: Self.draftKey)
            } catch {
                guard let self else { return }
                self.model.data.speak.reading = false
                self.model.data.notice = SpeakText.documentError(error) { $0.text }
            }
        }
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
        endReel()
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
        endReel()
        model.data.speak.selectedID = id
        model.data.speak.panelPhrase = nil
        model.data.speak.phase = .idle
        model.data.speak.trackMissing.remove(id)
        phrasesKey = nil
        cancelWaveform()
        ensureWaveform()
        ensurePhrases()
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
        // The panel's pinned sound and level reach the request only while Advanced is on; «Ещё вариант» is always a new sound.
        let knobs = VoicePanelModel.speechKnobs(panel: speak.panel, advanced: model.advanced)
        let seed = variant ? Int.random(in: 1...999_999_999) : knobs.seed
        let voice = speak.voice
        let language = VoicePick.languageHint(of: text).map { VoicePreview.language(locale: $0) }
        model.data.speak.phase = .generating
        let token = generation.advance()
        let speech = host.speech
        request = Task { @MainActor [weak self] in
            do {
                let wav = try await speech.speak(text, voice: voice, language: language, seed: seed, loudnessLUFS: knobs.loudness)
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
              let start = SpeakStudio.start(text: speak.text, reel: speak.reel, advanced: model.advanced, panel: speak.panel) else { return }
        if let refusal = host.speechRefusal() {
            model.data.notice = refusal
            return
        }
        stopClip()
        let voice = speak.voice
        model.data.speak.phase = .generating
        let token = generation.advance()
        studioStart.begin(token)
        let voiceover = self.voiceover
        request = Task { @MainActor [weak self] in
            do {
                let job = try await voiceover.start(script: start.script, title: start.title, voice: voice,
                                                    format: start.format, options: start.options, fromWindow: true)
                guard let self else { return }
                guard self.generation.isCurrent(token) else {
                    // «Новый текст» moved on while it started: the project exists, the list will show it.
                    self.refreshProjects()
                    return
                }
                self.studioStart.end()
                self.record(answered: true)
                self.model.data.speak.projectVoices = SpeakStudio.rememberVoice(voice, for: job.id, in: self.model.data.speak.projectVoices)
                // A project that copies the recording's delivery takes no mood: remembered so its phrases draw no chip.
                if SpeakStudio.copiesRecording(start.options) { self.model.data.speak.projectCopies.insert(job.id) }
                self.model.data.speak.projects = SpeakList.overlay(projects: self.model.data.speak.projects, followed: job)
                self.selectProject(job.id)
            } catch {
                guard let self, self.generation.isCurrent(token) else { return }
                self.studioStart.end()
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
        // The track's ▶ never pauses a phrase's take: it ends it and starts the track from the top.
        if model.data.speak.playingPhrase != nil { stopClip() }
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
        model.data.speak.playingPhrase = nil
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
        syncCursor()
    }

    // MARK: cursor

    /// The one place the cursor timer follows the sound: it ticks iff `ClipAudio` says so (the clip sounds and Reduce Motion
    /// is off), and a clip that is not sounding has no cursor. `perform` calls it after every event, the end of a clip
    /// and the stop of one that already ended included, so no path can leave a timer running.
    private func syncCursor() {
        if audio.cursorTicks(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            guard positionTimer == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.audio.sound == .playing, self.model.data.speak.playingPhrase == nil else { return }
                    self.model.data.speak.playedFraction = Waveform.fraction(time: self.player.currentTime, duration: self.player.duration)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            positionTimer = timer
        } else {
            positionTimer?.invalidate()
            positionTimer = nil
            if audio.sound == .stopped, model.data.speak.playedFraction != 0 { model.data.speak.playedFraction = 0 }
        }
    }

    // MARK: waveform

    /// Forgets the bars and cancels the scan that is reading them: the selection moved on.
    private func cancelWaveform() {
        waveformReads.advance()
        waveformTask?.cancel()
        waveformTask = nil
        waveformKey = nil
        model.data.speak.peaks = []
    }

    /// Reads the bars of the selected track once per track, and again when its file changes (a re-render rewrites it). The
    /// scan runs off the main actor and stops when the selection moves; the answer of a track no longer selected is dropped.
    private func ensureWaveform() {
        let speak = model.data.speak
        let key: String
        let source: () -> Data?
        if let clip = speak.selectedClip {
            key = "clip:\(clip.id)"
            source = { clip.wav }
        } else if let job = speak.selectedProject, job.status == .done || job.status == .review, let path = job.outputPath {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            key = SpeakTrack.key(projectID: job.id, path: path, modified: attributes?[.modificationDate] as? Date,
                                 size: (attributes?[.size] as? NSNumber)?.intValue)
            source = { try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
        } else {
            if waveformKey != nil { cancelWaveform() }
            return
        }
        guard key != waveformKey else { return }
        cancelWaveform()
        waveformKey = key
        model.data.speak.playedFraction = 0
        if let id = speak.selectedID { model.data.speak.trackMissing.remove(id) }
        let token = waveformReads.advance()
        let id = speak.selectedID
        let bars = Self.waveformBars
        waveformTask = Task { @MainActor [weak self] in
            // The scan of a long track runs off the main actor; cancelling this task cancels it.
            let scan = Task.detached(priority: .utility) { source().map { Waveform.peaks(wav: $0, bins: bars) } }
            let peaks: [Float]? = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard let self, !Task.isCancelled, self.waveformReads.isCurrent(token) else { return }
            if let peaks { self.model.data.speak.peaks = peaks } else if let id { self.model.data.speak.trackMissing.insert(id) }
        }
    }

    // MARK: phrases

    /// The key of a finished project's track, the same one the waveform uses: it changes when the file is rewritten.
    private func trackKey(of job: ProduceJob) -> String? {
        guard job.status == .done || job.status == .review, let path = job.outputPath else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return SpeakTrack.key(projectID: job.id, path: path, modified: attributes?[.modificationDate] as? Date,
                              size: (attributes?[.size] as? NSNumber)?.intValue)
    }

    /// Reads the chunks of the selected finished project once per track (and again after a re-render). While the project
    /// runs the rows on screen stay as they are, and while a phrase is being worked on its own result lands instead.
    private func ensurePhrases() {
        let speak = model.data.speak
        guard let job = speak.selectedProject, !PhraseEditing.isBusy(speak.phraseWork, project: job.id), let key = trackKey(of: job), key != phrasesKey else { return }
        phrasesKey = key
        let token = phraseReads.advance()
        let client = host.client
        Task { @MainActor [weak self] in
            let chunks = try? await client.chunks(id: job.id)
            guard let self, self.phraseReads.isCurrent(token) else { return }
            guard let chunks else {
                self.phrasesKey = nil
                return
            }
            self.model.data.speak.phraseChunks = chunks
            self.model.data.speak.phrasesFor = job.id
        }
    }

    private func chunk(_ n: Int) -> ProduceChunkDetail? {
        model.data.speak.phraseChunks.first { $0.index == n }
    }

    /// ▶ on a phrase: its picked take sounds; ▶ again ends it. A missing file says so instead of staying silent.
    func playPhrase(_ n: Int) {
        guard let chunk = chunk(n), model.data.speak.selectedProject != nil else { return }
        if model.data.speak.playingPhrase == n {
            stopClip()
            return
        }
        guard let path = PhraseEditing.takeFile(of: chunk), FileManager.default.fileExists(atPath: path) else {
            model.data.notice = L10nKey.speakPhraseFileMissing.text
            return
        }
        stopClip()
        model.data.speak.playingPhrase = n
        model.data.speak.playedFraction = 0
        perform(audio.start(recordingRunning: host.meetings()?.recordingElapsed != nil), track: {
            try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        })
        if audio.sound != .playing { model.data.speak.playingPhrase = nil }
    }

    /// «Ещё вариант» on a phrase: one more variant of that phrase only, and it becomes the one that plays. The daemon renders
    /// it as a job, so the order (ask, wait, read, pick, wait, read) is `PhraseRegeneration`'s.
    func anotherVariant(_ n: Int) {
        guard let known = chunk(n)?.takeKeys else { return }
        phraseOperation(chunk: n, kind: .variant) { [voiceover = self.voiceover] client, id in
            try await PhraseRegeneration.run(chunk: n, known: known, steps: PhraseRegeneration.Steps(
                regenerate: { chunk in try await client.regenerate(id: id, chunk: chunk, takes: 1) },
                waitUntilIdle: { try await voiceover.followAndWait(id: id) },
                chunks: { try await client.chunks(id: id) },
                pick: { chunk, key in try await client.pick(id: id, chunk: chunk, take: key) }))
        }
    }

    /// «Выбрать другой вариант»: the next variant the phrase already has.
    func pickOtherVariant(_ n: Int) {
        guard let chunk = chunk(n), chunk.takeKeys.count > 1,
              let next = PhraseEditing.nextPick(current: chunk.pick, keys: chunk.takeKeys) else { return }
        phraseOperation(chunk: n, kind: .pick) { [voiceover = self.voiceover] client, id in
            try await client.pick(id: id, chunk: n, take: next)
            try await voiceover.followAndWait(id: id)
            return try await client.chunks(id: id)
        }
    }

    /// A mood chip: only this phrase is rendered again (`POST …/delivery` with one entry).
    func setMood(_ n: Int, _ mood: Mood?) {
        guard let current = chunk(n) else { return }
        let unchanged = mood == nil ? current.style == nil : PhraseEditing.mood(of: current.style) == mood
        guard !unchanged else { return }
        phraseOperation(chunk: n, kind: .mood) { [voiceover = self.voiceover] client, id in
            try await client.deliver(id: id, entries: [PhraseEditing.deliveryEntry(chunk: n, mood: mood)], loudness: nil)
            try await voiceover.followAndWait(id: id)
            return try await client.chunks(id: id)
        }
    }

    /// «Править текст…»: the phrase's words are replaced and only that phrase is rendered again.
    func editPhraseText(_ n: Int, _ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != chunk(n)?.text else { return }
        phraseOperation(chunk: n, kind: .text) { [voiceover = self.voiceover] client, id in
            try await client.editText(id: id, chunk: n, text: words)
            try await voiceover.followAndWait(id: id)
            return try await client.chunks(id: id)
        }
    }

    /// One change to one phrase of the selected project. Every one of them is refused by the daemon while the project runs
    /// (`PhraseEditing.canEditText`), so the page does not send it; a second one waits for the first. The phrase's row says
    /// what is being done until the project has ended, then the chunks are read again.
    /// True when the change was accepted and is on its way; false when a gate refused it (the panel then shows the value it
    /// really holds). `onFailure` runs when an accepted change fails on the daemon.
    @discardableResult
    private func phraseOperation(chunk n: Int, kind: PhraseWork.Kind,
                                 _ body: @escaping (StudioClient, String) async throws -> [ProduceChunkDetail],
                                 onFailure: (() -> Void)? = nil) -> Bool {
        guard let job = model.data.speak.selectedProject, !PhraseEditing.isBusy(model.data.speak.phraseWork, project: job.id),
              PhraseEditing.canEditText(status: job.status) else { return false }
        // The daemon works on one project at a time: a change to this one while another is being changed would be refused.
        guard model.data.speak.phraseWork == nil else {
            model.data.notice = StudioError.voiceoverRunning.message()
            return false
        }
        if let refusal = host.speechRefusal() {
            model.data.notice = refusal
            return false
        }
        // A take that sounds would go on playing the old audio while it is being replaced.
        stopClip()
        model.data.speak.phraseWork = PhraseWork(project: job.id, chunk: n, kind: kind)
        let client = host.client
        Task { @MainActor [weak self] in
            do {
                let chunks = try await body(client, job.id)
                guard let self else { return }
                self.model.data.speak.phraseWork = nil
                self.model.data.speak.panelEpoch &+= 1
                // The person may have moved to another project meanwhile: its phrases are not replaced by these.
                if self.model.data.speak.selectedID == job.id {
                    self.model.data.speak.phraseChunks = chunks
                    self.model.data.speak.phrasesFor = job.id
                }
                // The track was rewritten: its bars and its key are read again.
                self.phrasesKey = nil
                self.refreshProjects()
            } catch {
                guard let self else { return }
                self.model.data.speak.phraseWork = nil
                self.model.data.speak.panelEpoch &+= 1
                onFailure?()
                self.model.data.notice = SpeakText.notice(error) { $0.text }
                // The daemon may have stored part of the change (a mood lands before the render): the key is
                // cleared so the chunks are read again — the row must not keep a stale chip until reselect.
                self.phrasesKey = nil
                self.refreshProjects()
            }
        }
        return true
    }

    // MARK: voice panel

    /// The settings only a new voicing reads (quality, the recording's delivery, the sound's number, variants): kept as view
    /// preferences, never sent to a project that exists.
    func panelChanged(_ settings: VoicePanelSettings) {
        model.data.speak.panel = settings
        savePanel()
    }

    private func savePanel() {
        model.data.speak.panel.save(to: host.defaults)
    }

    /// «Громкость»: a finished project is levelled at once, as a delivery with the target and no render, and the choice is kept
    /// for later voicings. The daemon re-assembles the finished file as a job of its own (one at a time), so it goes through the
    /// same gate as a change to a phrase and the app waits for it before reading the project again. The choice is stored (and
    /// shown) only once the change is accepted, and put back if the daemon then fails it. «Как обычно» on a finished project
    /// sends nothing: it is kept for the next voicings only.
    func setLoudness(_ target: LoudnessTarget?) {
        let previous = model.data.speak.panel.loudness
        guard let target, let job = model.data.speak.selectedProject, VoicePanelModel.loudnessAppliesNow(status: job.status) else {
            model.data.speak.panel.loudness = target
            savePanel()
            return
        }
        let accepted = phraseOperation(chunk: PhraseWork.wholeProject, kind: .loudness, { [voiceover = self.voiceover] client, id in
            try await client.deliver(id: id, entries: [], loudness: target.lufs)
            try await voiceover.followAndWait(id: id)
            return try await client.chunks(id: id)
        }, onFailure: { [weak self] in
            self?.model.data.speak.panel.loudness = previous
            self?.savePanel()
        })
        guard accepted else { return }
        model.data.speak.panel.loudness = target
        savePanel()
    }

    /// «Темп» and «Пауза» for the chosen phrase or all of them: the track is put together again without a render.
    func setPace(_ slider: Double) { applyDelivery(.pace(slider), kind: .pace) }

    func setPause(_ seconds: Double) { applyDelivery(.pause(seconds), kind: .pause) }

    /// One batch of delivery entries for the panel's scope. A batch with nothing to change is not sent (the daemon answers 400 to
    /// an empty one), and chunks that belong to another project are never used.
    private func applyDelivery(_ change: PanelChange, kind: PhraseWork.Kind) {
        let speak = model.data.speak
        guard speak.phrasesFor == speak.selectedID,
              let scope = VoicePanelModel.scope(allText: speak.panelAllText, phrase: speak.panelPhrase, chunks: speak.phraseChunks) else { return }
        let entries = VoicePanelModel.deliveryEntries(chunks: speak.phraseChunks, scope: scope, change: change)
        guard !entries.isEmpty else { return }
        let chunk: Int
        switch scope {
        case .phrase(let n): chunk = n
        case .all: chunk = PhraseWork.wholeProject
        }
        let accepted = phraseOperation(chunk: chunk, kind: kind) { [voiceover = self.voiceover] client, id in
            try await client.deliver(id: id, entries: entries, loudness: nil)
            try await voiceover.followAndWait(id: id)
            return try await client.chunks(id: id)
        }
        // A refused change leaves the slider where the person put it: it starts again from the value the phrase has.
        if !accepted { model.data.speak.panelEpoch &+= 1 }
    }

    // MARK: the row's buttons

    /// A button of the open voiceover's row. The daemon's ones (stop, continue on battery, resume, delete) go through
    /// `SpeakRowActions.perform` and the app follows the project from its new state; Finder, the save panel and the first
    /// flagged phrase are the window's own. A refusal is said in the daemon's words on the notice bar.
    func runRowAction(_ action: SpeakRowAction) {
        guard let job = model.data.speak.selectedProject else { return }
        switch action {
        case .showInFinder:
            if let path = job.outputPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        case .save:
            saveProject(job)
        case .listenToFlagged:
            // The first part the automatic checks flagged plays; the phrase list below shows the others.
            if let n = model.data.speak.phraseChunks.first(where: { $0.status == .review })?.index { playPhrase(n) }
        case .stop, .continueOnBattery, .resume, .remove:
            let id = job.id
            let client = host.client
            let voiceover = self.voiceover
            Task { @MainActor [weak self] in
                do {
                    try await SpeakRowActions.perform(action, id: id, client: client)
                    if action != .remove { await voiceover.refollow(id: id) }
                } catch {
                    self?.model.data.notice = StudioError.plain(error)
                }
                self?.refreshProjects()
            }
        }
    }

    private func saveProject(_ job: ProduceJob) {
        guard let path = job.outputPath, FileManager.default.fileExists(atPath: path) else {
            model.data.notice = L10nKey.speakTrackMissing.text
            return
        }
        SpeakSave.presentFile(URL(fileURLWithPath: path), name: SpeakClips.fileName(forTitle: job.title), in: host.mainWindow()) { [weak self] saved in
            if !saved { self?.model.data.notice = L10nKey.speakSaveFailed.text }
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

    /// The finished track of a project: copied, not read into memory (a long one is hundreds of megabytes).
    @MainActor
    static func presentFile(_ source: URL, name: String, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // The panel has asked about replacing; the old file goes only once the copy has landed (ExportRules.install).
                try ExportRules.install(source, to: url)
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
