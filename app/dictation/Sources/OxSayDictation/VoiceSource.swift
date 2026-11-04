import AppKit
import AVFoundation
import DictationCore
import Foundation
import MainWindowUI

/// The Voices page's glue: it builds the daemon calls for `VoiceLibrarySession` (which decides everything), plays a
/// sample, and copies the session into the window's values. No decision lives here, so nothing here is tested
/// beyond the wiring pins; the behaviour is in DictationCore.
@MainActor
final class VoiceSource {
    private let model: MainWindowModel
    private let client: StudioClient
    private let session: VoiceLibrarySession
    /// «Описать словами»: the flow and its effects. `running` on it is what holds the version handshake.
    private let designer: VoiceDesigner
    /// «Взять из файла»: the picked clip and the typed fields while its sheet is up.
    private var fileAdd: VoiceFileAdd?
    /// The picked file being measured. A newer pick supersedes it (and cancels the task), as does a closed window;
    /// the generation is what drops the late answer.
    private var pickTask: Task<Void, Never>?
    private var pickGeneration = Generation()
    /// «Записать свой голос»: the reducer while its sheet is up, the take's samples (24 kHz, in memory until saved or
    /// dropped), the recorder and the timer of the take in progress, the meter and the review's playback. Every write
    /// to `record` passes one check: a phase that is not work frees the kept samples, and work that just ended
    /// releases the version handshake's deferred relaunch (the same hook the design path uses, VoiceDesigner.finish).
    private var record: VoiceRecording? {
        didSet {
            if record?.isWork != true { takeSamples = [] }
            if oldValue?.isWork == true, record?.isWork != true { workEnded() }
        }
    }
    private var takeSamples: [Float] = []
    private var recorder: MicRecorder?
    private var recordTimer: Timer?
    private let sampleCount = SampleCounter()
    private var recordLevels: [Float] = []
    private var recordPlaying = false
    /// Plays the sample through the default output at the system's volume; this class never changes the volume.
    private let player = AudioPlayer()
    /// The menu's voice list and read-aloud checkmarks follow every change of the library.
    private let changed: ([String]) -> Void
    /// Whether a meeting is being recorded right now, read live: a sample must never sound into one (VoicePreviewGate).
    private let recordingRunning: () -> Bool
    /// Whether a dictation is recording right now, read live: a take must never start beside it (the microphone).
    private let dictationRecording: () -> Bool
    /// Whether the sheet's window is already closed: a refused save then has nowhere to say why — the take is dropped.
    private let windowGone: () -> Bool
    /// Work the version handshake was held back for has ended (a take closed, saved or was thrown away): it runs again.
    private let workEnded: () -> Void

    init(model: MainWindowModel, client: StudioClient, speech: SpeechClient, defaults: UserDefaults,
         recordingRunning: @escaping () -> Bool, dictationRecording: @escaping () -> Bool,
         windowGone: @escaping () -> Bool, workEnded: @escaping () -> Void,
         designer: VoiceDesigner, changed: @escaping ([String]) -> Void) {
        self.model = model
        self.client = client
        self.designer = designer
        self.changed = changed
        self.recordingRunning = recordingRunning
        self.dictationRecording = dictationRecording
        self.windowGone = windowGone
        self.workEnded = workEnded
        session = VoiceLibrarySession(
            ops: VoiceLibraryOps(
                list: { try await client.voiceEntries() },
                setLabel: { id, label in try await client.setVoiceLabel(id: id, label: label) },
                delete: { id in try await client.deleteVoice(id: id) },
                speak: { text, voice, language in try await speech.speak(text, voice: voice, language: language) }),
            readPicks: {
                ReadAloudPicks(russian: defaults.string(forKey: DictationSettings.speakVoiceRUKey),
                               english: defaults.string(forKey: DictationSettings.speakVoiceENKey))
            },
            writePicks: { picks in
                for (key, value) in [(DictationSettings.speakVoiceRUKey, picks.russian), (DictationSettings.speakVoiceENKey, picks.english)] {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            })
        player.onFinish = { [weak self] in
            Task { @MainActor in
                self?.session.previewEnded()
                self?.recordPlaying = false
                self?.sync()
            }
        }
        designer.onChange = { [weak self] in self?.sync() }
        designer.libraryNames = { [weak self] in self?.takenNames() ?? [] }
        designer.mayPlay = { [recordingRunning] in VoicePreviewGate.allows(recordingRunning: recordingRunning()) }
        designer.willPlay = { [weak self] in
            self?.player.stop()
            self?.recordPlaying = false
            self?.session.stopPreview()
            self?.sync()
        }
        designer.saved = { [weak self] voice, label in await self?.designSaved(voice, label: label) }
    }

    // MARK: describe a voice

    /// One step of the sheet.
    func design(_ step: VoiceDesignAction) {
        switch step {
        case .open: designer.open()
        case .submit(let description, let sentence, let label): designer.submit(description: description, sentence: sentence, label: label)
        case .next: designer.next()
        case .replay: designer.replay()
        case .keep: designer.keep()
        case .replace(let yes): designer.replace(yes)
        case .escape: designer.escape()
        case .edit(let description, let sentence, let label): designer.edit(description: description, sentence: sentence, label: label)
        }
    }

    /// The window closed or hid: a variant that plays is stopped.
    func quietDesign() { designer.quiet() }

    // MARK: take from a file

    /// One step of the file sheet.
    func file(_ step: VoiceFileAction) {
        switch step {
        case .picked(let url): pickFile(url)
        case .edit(let label, let refText): fileAdd?.edit(label: label, refText: refText); sync()
        case .add: submitFile()
        case .escape: if fileAdd?.mayClose != false { fileAdd = nil; sync() }
        }
    }

    /// The picked file is measured — its size and, when the local decode manages, its duration — before the sheet
    /// shows. The app is not sandboxed (the entitlements are apple-events and audio-input only), so the chosen file's
    /// absolute path reads without a security scope and is what the daemon gets. A probe that answers after a newer
    /// pick (or after the window closed) is stale: the generation drops it, it never opens a sheet.
    private func pickFile(_ url: URL) {
        let path = url.path
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        let token = pickGeneration.advance()
        pickTask?.cancel()
        pickTask = Task { @MainActor in
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            guard pickGeneration.isCurrent(token) else { return }
            fileAdd = VoiceFileAdd(fileName: url.lastPathComponent, audioPath: path,
                                   seconds: seconds?.isFinite == true ? seconds : nil,
                                   bytes: bytes, ext: url.pathExtension)
            sync()
        }
    }

    /// The window closed or hid: a probe still measuring has nowhere to land — drop its answer.
    func quietFile() {
        pickGeneration.advance()
        pickTask?.cancel()
        pickTask = nil
    }

    /// «Добавить»: the model decides whether the form may send; a 400/409 shows the daemon's own sentence in the
    /// sheet and keeps the input, a save refreshes the library through the session (its sole owner).
    private func submitFile() {
        guard var draft = fileAdd, let request = draft.submit(taken: takenNames()) else { sync(); return }
        fileAdd = draft
        sync()
        Task { @MainActor in
            do {
                let voice = try await client.addVoice(id: request.id, label: request.label,
                                                      audioPath: request.audioPath, refText: request.refText,
                                                      source: "file")
                fileAdd = nil
                await session.reload()
                sync()
                model.data.notice = DesignForm.savedNotice(name: request.label, shortened: voice.notice != nil)
            } catch {
                fileAdd?.refused(StudioError.plain(error))
                sync()
            }
        }
    }

    // MARK: record your own voice

    /// A voice recording holds the relaunch: a take in progress, kept for review or being sent would be lost.
    var recordingVoice: Bool { record?.isWork ?? false }

    /// One step of the record sheet. The reducer decides; this carries out the effect it returns.
    func recording(_ step: VoiceRecordAction) {
        switch step {
        case .open: openRecording()
        case .start: startTake()
        case .stop: stopTake()
        case .nextPrompt: mutate { $0.nextPrompt() }
        case .play: playTake()
        case .stopPlay: player.stop(); recordPlaying = false; sync()
        case .openSettings:
            if let url = URL(string: PermissionPane.microphone.settingsURL) { NSWorkspace.shared.open(url) }
        case .edit(let label): record?.edit(label: label); sync()
        case .save: saveTake()
        case .escape: closeRecording()
        }
    }

    /// The sheet opens without asking: an allowed or denied microphone shows at once, an undecided one waits for the
    /// first «Записать» (the question is raised there, never at open).
    private func openRecording() {
        var r = VoiceRecording(language: L10nBundle.locale.identifier, taken: takenNames())
        let status = microphoneStatus()
        if status != .notDetermined { _ = r.micStatus(status) }
        record = r
        takeSamples = []
        sync()
    }

    private func microphoneStatus() -> PermissionAuth {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// The window is back in front (from System Settings, say): a microphone that was refused may be allowed now.
    func microphoneMayHaveChanged() {
        guard var r = record, case .needsMicrophone = r.phase else { return }
        _ = r.micStatus(microphoneStatus())
        record = r
        sync()
    }

    /// Applies a reducer step to the sheet's state and performs the effect it returns.
    private func change(_ step: (inout VoiceRecording) -> VoiceRecording.Effect?) {
        guard var r = record else { return }
        let effect = step(&r)
        record = r
        if let effect { perform(effect) }
        sync()
    }

    private func mutate(_ step: (inout VoiceRecording) -> Void) {
        change { r -> VoiceRecording.Effect? in step(&r); return nil }
    }

    private func perform(_ effect: VoiceRecording.Effect) {
        switch effect {
        case .askMicrophone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.microphoneMayHaveChanged() }
            }
        case .startRecorder: startRecorder()
        case .stopRecorder: takeSamples = Array(endRecorder().prefix(VoiceRecording.sampleRate * Int(VoiceRecording.maximumSeconds)))
        case .discardTake: discardTake()
        }
    }

    /// «Записать»: the microphone is read now. Undecided raises the macOS question and waits; a meeting or a
    /// dictation recording refuses (all three use the microphone).
    private func startTake() {
        player.stop()
        recordPlaying = false
        let status = microphoneStatus()
        change { r in
            let asked = r.micStatus(status)
            if asked != nil { return asked }
            return r.start(meetingRecording: recordingRunning(), dictationRecording: dictationRecording(),
                           text: { $0.text })
        }
    }

    private func startRecorder() {
        takeSamples = []
        recordLevels = []
        sampleCount.reset()
        let mic = MicRecorder(sampleRate: VoiceRecording.sampleRate)
        mic.maxSeconds = VoiceRecording.maximumSeconds + 2
        mic.onLevels = { [weak self] levels in DispatchQueue.main.async { self?.levelsArrived(levels) } }
        mic.onSamples = { [sampleCount] chunk in sampleCount.add(chunk.count) }
        mic.onEnded = { [weak self] _ in Task { @MainActor in self?.stopTake() } }
        do {
            try mic.prepare()
            try mic.start()
        } catch {
            record?.recorderFailed(RecorderError.reason(error))
            return
        }
        recorder = mic
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTake() }
        }
    }

    private func tickTake() {
        let seconds = Double(sampleCount.value) / Double(VoiceRecording.sampleRate)
        change { $0.tick(seconds: seconds) }
    }

    private func levelsArrived(_ levels: [Float]) {
        guard recorder != nil else { return }
        recordLevels = levels
        sync()
    }

    /// Stops the recorder and the timer and returns what it kept.
    private func endRecorder() -> [Float] {
        recordTimer?.invalidate()
        recordTimer = nil
        let samples = recorder?.stop() ?? []
        recorder = nil
        recordLevels = []
        return samples
    }

    private func discardTake() {
        _ = endRecorder()
        takeSamples = []
        player.stop()
        recordPlaying = false
    }

    /// «Остановить»: the take goes to the review with the length the recorder really kept.
    private func stopTake() {
        guard record?.phase == .recording else { return }
        takeSamples = Array(endRecorder().prefix(VoiceRecording.sampleRate * Int(VoiceRecording.maximumSeconds)))
        let seconds = Double(takeSamples.count) / Double(VoiceRecording.sampleRate)
        mutate { $0.stop(seconds: seconds) }
    }

    private func playTake() {
        guard !takeSamples.isEmpty else { return }
        session.stopPreview()
        do {
            try player.play(wav: WAV.pcm16(takeSamples, sampleRate: VoiceRecording.sampleRate))
            recordPlaying = true
        } catch {
            recordPlaying = false
            model.data.notice = SpeechError.plain(error, whilePlaying: true)
        }
        sync()
    }

    /// Esc or the close: a take is stopped and dropped; while it is being sent the sheet stays.
    private func closeRecording() {
        guard var r = record, r.mayClose else { return }
        if let effect = r.escape() { perform(effect) }
        record = nil
        takeSamples = []
        sync()
    }

    /// A meeting recording started: a take is stopped and thrown away, the sheet says why.
    func meetingStarted() {
        change { $0.meetingStarted() }
    }

    /// The window closed or hid: a take in progress stops and is dropped.
    func quietRecording() {
        closeRecording()
    }

    /// «Сохранить»: the take is written to a private temp folder, sent, and the folder removed — whatever the answer.
    private func saveTake() {
        guard var r = record else { return }
        let request = r.save(taken: takenNames())
        record = r
        sync()
        guard let request else { return }
        let samples = takeSamples
        player.stop()
        recordPlaying = false
        Task { @MainActor in
            do {
                let voice = try await addRecordedVoice(request, samples: samples)
                record = nil
                takeSamples = []
                await session.reload()
                sync()
                model.data.notice = DesignForm.savedNotice(name: request.label, shortened: voice.notice != nil)
            } catch {
                // The window closed while the take was being sent: there is nowhere to say why — the take goes.
                if record?.refused(StudioError.plain(error), windowGone: windowGone()) == .discardTake {
                    perform(.discardTake)
                    record = nil
                }
                sync()
            }
        }
    }

    /// The person's voice must not stay on disk: the 0700 folder and the clip in it go when this returns, on success
    /// and on failure alike.
    private func addRecordedVoice(_ request: VoiceRecording.Request, samples: [Float]) async throws -> SavedVoice {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-voice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let clip = dir.appendingPathComponent("voice.wav")
        guard FileManager.default.createFile(atPath: clip.path,
                                             contents: WAV.pcm16(samples, sampleRate: VoiceRecording.sampleRate),
                                             attributes: [.posixPermissions: 0o600]) else { throw RecorderError.noInput }
        return try await client.addVoice(id: request.id, label: request.label, audioPath: clip.path,
                                         refText: request.refText, source: "recorded")
    }

    /// The ids and lower-cased labels the library holds: a label that names one of them is refused by the form.
    private func takenNames() -> Set<String> {
        Set(session.entries.flatMap { [$0.id, $0.label.lowercased()] })
    }

    /// A voice was saved. The list is read through the session (the one owner of it), the label the person typed is set
    /// through its rename (a PATCH of the label), and the result is said in the window.
    private func designSaved(_ voice: SavedVoice, label: String) async {
        await session.reload()
        var problem: String?
        if !label.isEmpty { problem = await session.rename(id: voice.name, label: label) }
        sync()
        model.data.notice = problem ?? DesignForm.savedNotice(name: label.isEmpty ? voice.name : label, shortened: voice.notice != nil)
    }

    func reload() {
        Task { @MainActor in
            await session.reload()
            sync()
        }
    }

    func rename(_ id: String, _ label: String) {
        Task { @MainActor in
            let notice = await session.rename(id: id, label: label)
            sync()
            if let notice { model.data.notice = notice }
        }
    }

    func delete(_ id: String) {
        Task { @MainActor in
            if session.playingID == id { player.stop() }
            let notice = await session.delete(id: id)
            sync()
            if let notice { model.data.notice = notice }
        }
    }

    func preview(_ id: String) {
        player.stop()
        recordPlaying = false
        // A recording captures the output: a sample must never start into one. Read live — it may have just begun.
        guard VoicePreviewGate.allows(recordingRunning: recordingRunning()) else {
            session.stopPreview()
            model.data.notice = L10nKey.voicesPreviewBlockedRecording.text
            sync()
            return
        }
        Task { @MainActor in
            sync(playing: id)
            let outcome = await session.preview(id: id, locale: L10nBundle.locale.identifier)
            switch outcome {
            case .play(let wav):
                // A stop, a newer preview or a delete that landed while the sample was being made: it never starts.
                guard session.playingID == id else { break }
                // The recording may have begun while the sample was being made.
                guard VoicePreviewGate.allows(recordingRunning: recordingRunning()) else {
                    session.stopPreview()
                    model.data.notice = L10nKey.voicesPreviewBlockedRecording.text
                    break
                }
                do {
                    try player.play(wav: wav)
                } catch {
                    session.stopPreview()
                    model.data.notice = SpeechError.plain(error, whilePlaying: true)
                }
            case .dropped: break
            case .failed(let sentence): model.data.notice = sentence
            }
            sync()
        }
    }

    func stopPreview() {
        player.stop()
        recordPlaying = false
        session.stopPreview()
        sync()
    }

    /// The session's list, picks and playing voice into the window, and the menu's list and checkmarks after them —
    /// the menu only when the ids actually moved. The player answers to the session: a sample it no longer calls
    /// playing (a delete may have stopped it mid-flight) is stopped — unless it is the person's own take.
    private func sync(playing: String? = nil) {
        var values = model.data.voices
        let previousIDs = values.voices
        values.entries = session.entries
        values.load = session.load
        values.playingID = playing ?? session.playingID
        values.russianVoice = session.picks.russian
        values.englishVoice = session.picks.english
        if let offered = session.offeredIDs { values.voices = offered }
        if VoicePlayback.shouldStop(previewID: session.playingID, takePlaying: recordPlaying, active: player.isActivelyPlaying) {
            player.stop()
        }
        values.design = designer.flow
        values.designOpen = designer.sheetOpen
        values.file = fileAdd
        values.record = record.map { VoiceRecordValues(recording: $0, levels: recordLevels, playing: recordPlaying) }
        if values != model.data.voices { model.data.voices = values }
        if values.voices != previousIDs { changed(values.voices) }
    }
}

/// The samples a take has kept so far, counted on the audio thread and read by the main-thread timer.
private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int) { lock.withLock { count += n } }
    func reset() { lock.withLock { count = 0 } }
}
