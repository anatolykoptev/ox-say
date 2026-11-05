import AppKit
import DictationCore

/// What the Studio features need from the app around them; closures, so the
/// studio code never reaches into AppDelegate.
struct StudioHost {
    var client: StudioClient
    var speech: SpeechClient
    /// The Russian voice pick of the Voice menu, preselected in the voiceover form.
    var russianVoicePick: () -> String?
    /// Shows a modal alert over every app and returns the pressed button.
    var alert: (_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse
    /// The pill of Studio task `task` with this text, or that task's end for nil. Each task has its own
    /// slot: one ending never takes another's pill down (TaskPills).
    var pill: (_ task: String, _ text: String?) -> Void
    /// A short message in the status line and on the pill.
    var notify: (String) -> Void
    /// Plays a WAV; `onFinish` runs once when it ends on its own.
    var play: (_ wav: Data, _ showPill: Bool, _ onFinish: (() -> Void)?) -> Void
    var stopPlayback: () -> Void
    /// How many clips the shared player has started; a variant stops only if it is still the last one.
    var playbackSerial: () -> Int
    /// Confirms and runs the studio voice install.
    var installStudioVoice: () -> Void
    var installing: () -> Bool
    /// Work the studio was doing has ended (a voiceover finished or was forgotten,
    /// a voice design closed): a version handshake held back for it runs again.
    var workEnded: () -> Void
    /// The Create a Voice menu row: the window opens on Voices with the describe-a-voice sheet up.
    var openVoiceDesign: () -> Void
    /// The main window is on screen (shown, not minimised or covered).
    var windowVisible: () -> Bool
}

/// The Studio submenu: draws the rows StudioMenu decides, and runs the three
/// flows behind them — a long voiceover and following it to the end; a new voice opens the window's sheet.
final class StudioController: NSObject {
    let submenu = NSMenu()
    let host: StudioHost
    private var service = StudioMenu.ServiceState.unknown
    private var latestFolder: URL?
    /// A document is being read: the menu row waits and the pill says so.
    private var readingDocument = false
    static let readingPillTask = "reading-document"
    /// The voiceover being followed; the window's Озвучка page starts and reads the same one.
    let voiceover: VoiceoverService
    /// Describe a voice: the window's sheet drives it, the menu row opens that sheet.
    lazy var designer = VoiceDesigner(host: host)

    init(host: StudioHost) {
        self.host = host
        voiceover = VoiceoverService(client: host.client)
        super.init()
        submenu.autoenablesItems = false
        voiceover.observe(
            onChange: { [weak self] in
                self?.render()
                if self?.voiceover.following == false { self?.host.workEnded() }
            },
            onFinish: { [weak self] job in
                guard let self else { return }
                self.refreshFolder()
                // A project started on Озвучка and finished with the window in view is already on the page.
                guard FinishNotice.shouldAlert(startedOnPage: self.voiceover.startedOnPage(job.id),
                                               windowVisible: self.host.windowVisible()) else { return }
                self.presentFinish(job)
            })
    }

    /// A voice design is running or its takes are being reviewed.
    var designing: Bool { designer.running }

    // MARK: menu

    func render() {
        let folderExists = latestFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let rows = StudioMenu.rows(
            service: service, installing: host.installing(), job: voiceover.job,
            serviceWaiting: voiceover.serviceWaiting, hasOutputFolder: folderExists,
            readingDocument: readingDocument)
        MenuRenderer.fill(submenu, rows: rows, target: self) { action in (#selector(choose(_:)), action) }
    }

    /// The daemon's /status arrived (or failed): redraw, look for the latest
    /// voiceover's folder, and pick up a voiceover already running.
    func statusChanged(_ new: DaemonStatus?) {
        service = new.map { .answered($0) } ?? .unreachable
        if StudioPickup.lookOnStatus(new) { voiceover.serviceAnswered() }
        if new?.studioAvailable == true { refreshFolder() }
        render()
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .installStudioVoice: host.installStudioVoice()
        case .newVoiceover: newVoiceover()
        case .stopVoiceover: stopVoiceover()
        case .continueOnBattery: continueOnBattery()
        case .openVoiceoversFolder: openFolder()
        case .createVoice: host.openVoiceDesign()
        case .pickVoice, .pickDictationKey, .pickSpeakKey, .copyDictation, .pasteLastDictation: break
        case .startMeeting, .stopMeeting, .installNotesModel, .openMeetingsFolder, .chooseMeetingsFolder,
             .setMeetingName, .pickMeetingCallMode, .pickMeetingRetention, .editSpeakers, .retryVoices: break
        }
    }

    private func refreshFolder() {
        Task { @MainActor [weak self] in
            guard let self, let jobs = try? await self.host.client.voiceovers() else { return }
            self.latestFolder = jobs.first(where: { $0.outputPath != nil })?.outputFolder
            self.render()
        }
    }

    // MARK: finishing

    /// Shows `dialog` over every app and returns the pressed button.
    @discardableResult
    private func show(_ dialog: UpdateDialog) -> NSApplication.ModalResponse {
        host.alert(dialog.title, dialog.text, dialog.buttons)
    }

    /// "Voiceover ready" with Show in Finder / Play / OK, or why it failed.
    private func presentFinish(_ finished: ProduceJob) {
        guard let dialog = StudioDialogs.finished(finished) else { return }
        guard let path = finished.outputPath else {
            show(dialog)
            return
        }
        let url = URL(fileURLWithPath: path)
        switch show(dialog) {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertSecondButtonReturn:
            guard let wav = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                show(StudioDialogs.playFailed())
                return
            }
            host.play(wav, true) { [weak self] in self?.presentFinish(finished) }
        default:
            break
        }
    }

    // MARK: flows

    private func newVoiceover() {
        guard let file = StudioForms.chooseDocument() else { return }
        Task { @MainActor [weak self] in
            guard let self, let script = await self.readScript(file) else { return }
            guard let voices = try? await self.host.speech.voices() else {
                self.show(StudioDialogs.serviceDown())
                return
            }
            let choices = StudioMenu.voiceChoices(voices: voices, russianPick: self.host.russianVoicePick())
            let first = ReviewSheet.Result(title: StudioMenu.defaultTitle(fileName: file.lastPathComponent), script: script,
                                           format: ProduceFormat.allCases[0], voice: choices.names[choices.selected])
            // A start the daemon refuses reopens the sheet with the person's text, not the first cleaning.
            // The service follows the job it starts.
            _ = await ReviewRetry.run(first, review: { ReviewSheet(draft: $0, voiceNames: choices.names).run() },
                start: { [voiceover = self.voiceover] draft in
                    try await voiceover.start(script: draft.script, title: draft.title, voice: draft.voice, format: draft.format)
                },
                failed: { error in
                    self.show(StudioDialogs.startFailed(error))
                })
        }
    }

    /// The cleaned text of the document, or nil after telling the person why there is none.
    private func readScript(_ file: URL) async -> String? {
        readingDocument = true
        render()
        host.pill(Self.readingPillTask, L10nKey.studioReadingPill.text)
        defer {
            readingDocument = false
            render()
            host.pill(Self.readingPillTask, nil)
        }
        do {
            let read = try await DocumentReader.readScript(file)
            if read.script.isEmpty { show(StudioDialogs.nothingToRead(read)) }
            return read.script.isEmpty ? nil : read.script
        } catch {
            show(StudioDialogs.readFailed(error))
            return nil
        }
    }

    private func stopVoiceover() {
        guard let job = voiceover.job else { return }
        let sure = show(StudioDialogs.stop())
        guard sure == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.voiceover.stop()
            } catch {
                self?.show(StudioDialogs.stopFailed(error))
            }
        }
    }

    private func continueOnBattery() {
        guard let job = voiceover.job else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.voiceover.continueOnBattery()
            } catch {
                self?.show(StudioDialogs.continueFailed(error))
            }
        }
    }

    private func openFolder() {
        if let latestFolder { NSWorkspace.shared.open(latestFolder) }
    }

}
