import AppKit
import DictationCore

/// Create a Voice: the form, the daemon's three takes, and listening to them
/// one by one until one is kept. Every decision (what is valid, what a 409
/// means) is in DictationCore; this drives the dialogs.
final class VoiceDesigner {
    private let host: StudioHost
    /// This task's pill slot (TaskPills): a document read at the same time has its own.
    static let pillTask = "designing-voice"
    /// True from the form being answered until the takes are kept or dropped.
    private(set) var running = false

    /// What was typed last, so a second voice starts from it.
    private var lastForm = StudioForms.VoiceDesign(description: "", sentence: DesignForm.defaultSentence, name: "")

    init(host: StudioHost) {
        self.host = host
    }

    func start() {
        guard !running, let form = StudioForms.designForm(preset: lastForm) else { return }
        lastForm = form
        running = true
        host.pill(Self.pillTask, L10nKey.designDesigningPill.text)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.running = false
                self.host.workEnded()
            }
            do {
                let takes = try await self.host.client.designVoice(description: form.description, text: form.sentence)
                self.host.pill(Self.pillTask, nil)
                await self.review(takes, typedName: form.name)
            } catch {
                self.host.pill(Self.pillTask, nil)
                _ = self.host.alert(L10nKey.designFailedTitle.text, StudioError.plain(error), [L10nKey.commonOk.text])
            }
        }
    }

    /// Plays each take and asks; the next-take button cycles so an earlier one can be reconsidered.
    private func review(_ takes: [DesignTake], typedName: String) async {
        var index = 0
        var replay = true
        defer { host.stopPlayback() }
        while true {
            let take = takes[index]
            if replay { play(take) }
            replay = true
            let name = DesignForm.saveName(typed: typedName, take: take)
            var text = L10nKey.designTakeSavedAs.text(name)
            if let warning = take.warning { text = DesignForm.warningText(warning) + "\n\n" + text }
            let answer = host.alert(DesignForm.takeTitle(index: index, count: takes.count), text,
                                    [L10nKey.designTakeKeep.text, L10nKey.designTakeNext.text,
                                     L10nKey.designTakeReplay.text, L10nKey.commonCancel.text])
            switch answer {
            case .alertFirstButtonReturn:
                if await save(name: name, take: take) { return }
                replay = false
            case .alertSecondButtonReturn:
                index = (index + 1) % takes.count
            case .alertThirdButtonReturn:
                break
            default:
                return
            }
        }
    }

    private func play(_ take: DesignTake) {
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: take.path)) else {
            _ = host.alert(L10nKey.designPlayFailedTitle.text, L10nKey.designPlayFailedText.text, [L10nKey.commonOk.text])
            return
        }
        host.play(wav, false, nil)
    }

    /// True when the voice is saved. A taken name is asked about, then retried with replace.
    private func save(name: String, take: DesignTake) async -> Bool {
        do {
            var outcome = try await host.client.saveDesign(name: name, take: take.path, replace: false)
            if outcome == .nameTaken {
                let sure = host.alert(L10nKey.designExistsTitle.text(name), L10nKey.designExistsText.text,
                                      [L10nKey.designExistsButton.text, L10nKey.commonCancel.text])
                guard sure == .alertFirstButtonReturn else { return false }
                outcome = try await host.client.saveDesign(name: name, take: take.path, replace: true)
            }
            guard case .saved(let voice) = outcome else {
                _ = host.alert(L10nKey.designSaveFailedTitle.text, L10nKey.designSaveFailedExists.text, [L10nKey.commonOk.text])
                return false
            }
            host.notify(DesignForm.savedNotice(name: voice.name, shortened: voice.notice != nil))
            return true
        } catch {
            _ = host.alert(L10nKey.designSaveFailedTitle.text, StudioError.plain(error), [L10nKey.commonOk.text])
            return false
        }
    }
}
