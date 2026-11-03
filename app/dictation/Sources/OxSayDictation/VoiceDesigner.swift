import AppKit
import DictationCore

/// Describe a voice: carries out what `VoiceDesignFlow` decides. It owns the flow and the effects (the daemon's design
/// and save, playing a variant) and nothing else: every decision (what is valid, which variant is next, what a taken
/// name means) is in DictationCore. The window's sheet shows `flow`; `onChange` tells it to repaint. The class is not
/// main-actor isolated so that `running` can be read from anywhere (the version handshake); every step is.
final class VoiceDesigner {
    private let host: StudioHost
    /// This task's pill slot (TaskPills): a document read at the same time has its own.
    static let pillTask = "designing-voice"

    /// What the sheet shows. Starts from the text typed last, so a second voice begins where the first left off.
    private(set) var flow = VoiceDesignFlow()
    private(set) var sheetOpen = false
    /// True from the form being answered until the variants are kept or dropped: the version handshake reads it
    /// through `studio.designing`, so the app is never relaunched mid-design.
    var running: Bool { flow.isBusy }

    /// Every step ends here: the window repaints.
    var onChange: @MainActor () -> Void = {}
    /// The ids and lower-cased labels of the voices that exist, for the form to refuse a name that is taken.
    var libraryNames: @MainActor () -> Set<String> = { [] }
    /// A variant may sound now (never into a meeting recording; VoicePreviewGate).
    var mayPlay: @MainActor () -> Bool = { true }
    /// Another sample is about to sound: the window stops its own.
    var willPlay: @MainActor () -> Void = {}
    /// A voice was saved under `voice.name`; the window refreshes its list and sets the label.
    var saved: @MainActor (_ voice: SavedVoice, _ label: String) async -> Void = { _, _ in }

    private var pillUp = false
    /// Which playback on the app's shared player is a variant of this design (VariantPlayback).
    private var variant = VariantPlayback()

    init(host: StudioHost) {
        self.host = host
    }

    // MARK: the sheet's steps

    @MainActor
    func open() {
        if !flow.isBusy { _ = flow.cancel() }
        sheetOpen = true
        onChange()
    }

    @MainActor
    func submit(description: String, sentence: String, label: String) {
        flow.description = description
        flow.sentence = sentence
        flow.label = label
        let effect = flow.submit(taken: libraryNames(), recordingRunning: !mayPlay())
        perform(effect)
    }

    /// The form's text as it is typed: Cancel keeps it.
    @MainActor
    func edit(description: String, sentence: String, label: String) {
        flow.edit(description: description, sentence: sentence, label: label)
    }

    @MainActor
    func next() { perform(flow.next()) }
    @MainActor
    func replay() { perform(flow.replay()) }
    @MainActor
    func keep() { perform(flow.keep()) }
    @MainActor
    func replace(_ yes: Bool) { perform(flow.confirmReplaceAnswered(yes)) }

    @MainActor
    func escape() {
        let closed = flow.escape()
        if closed != nil { sheetOpen = false }
        perform(closed)
    }

    /// The window closed or hid: whatever variant plays stops.
    @MainActor
    func quiet() { stopVariant() }

    /// Stops the variant this designer started, and only that: the shared player may be carrying a voiceover or a
    /// read-aloud, which a close of the window must not cut.
    @MainActor
    private func stopVariant() {
        if variant.mayStop(current: host.playbackSerial()) { host.stopPlayback() }
        variant.released()
    }

    // MARK: effects

    @MainActor
    private func perform(_ effect: VoiceDesignEffect?) {
        let wasRunning = running
        switch effect {
        case .design(let description, let sentence): design(description, sentence)
        case .play(let take): play(take)
        case .save(let id, let label, let take, let replace): save(id: id, label: label, take: take, replace: replace)
        case .stopPlayback: stopVariant()
        case nil: break
        }
        finish(wasRunning: wasRunning)
    }

    /// The pill and the version handshake follow the flow: the pill while the variants are made, the handshake once the
    /// work has ended.
    @MainActor
    private func finish(wasRunning: Bool) {
        if case .designing = flow.phase {
            pillUp = true
        } else if pillUp {
            pillUp = false
            host.pill(Self.pillTask, nil)
        }
        onChange()
        if wasRunning && !running { host.workEnded() }
    }

    @MainActor
    private func design(_ description: String, _ sentence: String) {
        // The answer carries the number of the design it was asked for; the flow drops one that is not current.
        let mine = flow.generation
        host.pill(Self.pillTask, L10nKey.designDesigningPill.text)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let takes = try await self.host.client.designVoice(description: description, text: sentence)
                let wasRunning = self.running
                self.flow.designed(takes, for: mine)
                if let first = self.flow.currentTake { self.play(first) }
                self.finish(wasRunning: wasRunning)
            } catch {
                let wasRunning = self.running
                self.flow.fail(StudioError.plain(error), for: mine)
                self.finish(wasRunning: wasRunning)
            }
        }
    }

    @MainActor
    private func play(_ take: DesignTake) {
        guard mayPlay() else {
            flow.playRefused(L10nKey.voicesPreviewBlockedRecording.text)
            return
        }
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: take.path)) else {
            flow.playRefused(L10nKey.designPlayFailedText.text)
            return
        }
        willPlay()
        host.play(wav, false, nil)
        variant.started(serial: host.playbackSerial())
    }

    /// A taken name comes back as `.nameTaken` and the flow asks; the answer is one more save with replace.
    @MainActor
    private func save(id: String, label: String, take: String, replace: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wasRunning = self.running
            do {
                let outcome = try await self.host.client.saveDesign(name: id, take: take, replace: replace)
                self.flow.saveAnswered(outcome)
                self.onChange()
                if case .saved(let voice) = outcome {
                    // The label and the list are the window's (VoiceSource). The flow stays busy (`.done`) until they
                    // are done, so the version handshake cannot relaunch the app between the save and the label.
                    await self.saved(voice, label)
                    self.stopVariant()
                    self.sheetOpen = false
                    _ = self.flow.cancel()
                } else if replace {
                    // Asked to replace and told the name is taken again: not a question to ask twice.
                    self.flow.fail(L10nKey.designSaveFailedExists.text)
                }
            } catch {
                self.flow.fail(StudioError.plain(error))
            }
            self.finish(wasRunning: wasRunning)
        }
    }
}
