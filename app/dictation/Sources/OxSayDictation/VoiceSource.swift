import DictationCore
import Foundation
import MainWindowUI

/// The Voices page's glue: it builds the daemon calls for `VoiceLibrarySession` (which decides everything), plays a
/// sample, and copies the session into the window's values. No decision lives here, so nothing here is tested
/// beyond the wiring pins; the behaviour is in DictationCore.
@MainActor
final class VoiceSource {
    private let model: MainWindowModel
    private let session: VoiceLibrarySession
    /// Plays the sample through the default output at the system's volume; this class never changes the volume.
    private let player = AudioPlayer()
    /// The menu's voice list and read-aloud checkmarks follow every change of the library.
    private let changed: ([String]) -> Void
    /// Whether a meeting is being recorded right now, read live: a sample must never sound into one (VoicePreviewGate).
    private let recordingRunning: () -> Bool

    init(model: MainWindowModel, client: StudioClient, speech: SpeechClient, defaults: UserDefaults,
         recordingRunning: @escaping () -> Bool, changed: @escaping ([String]) -> Void) {
        self.model = model
        self.changed = changed
        self.recordingRunning = recordingRunning
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
                self?.sync()
            }
        }
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
        session.stopPreview()
        sync()
    }

    /// The session's list, picks and playing voice into the window, and the menu's list and checkmarks after them —
    /// the menu only when the ids actually moved. The player answers to the session: a sample it no longer calls
    /// playing (a delete may have stopped it mid-flight) is stopped.
    private func sync(playing: String? = nil) {
        var values = model.data.voices
        let previousIDs = values.voices
        values.entries = session.entries
        values.load = session.load
        values.playingID = playing ?? session.playingID
        values.russianVoice = session.picks.russian
        values.englishVoice = session.picks.english
        if let offered = session.offeredIDs { values.voices = offered }
        if session.playingID == nil, player.isActivelyPlaying { player.stop() }
        if values != model.data.voices { model.data.voices = values }
        if values.voices != previousIDs { changed(values.voices) }
    }
}
