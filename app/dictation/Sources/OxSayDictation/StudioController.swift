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
    /// The pill with this text, or hides it for nil.
    var pill: (String?) -> Void
    /// A short message in the status line and on the pill.
    var notify: (String) -> Void
    /// Plays a WAV; `onFinish` runs once when it ends on its own.
    var play: (_ wav: Data, _ showPill: Bool, _ onFinish: (() -> Void)?) -> Void
    var stopPlayback: () -> Void
    /// Confirms and runs the studio voice install.
    var installStudioVoice: () -> Void
    var installing: () -> Bool
    /// Work the studio was doing has ended (a voiceover finished or was forgotten,
    /// a voice design closed): a version handshake held back for it runs again.
    var workEnded: () -> Void
}

/// The Studio submenu: draws the rows StudioMenu decides, and runs the three
/// flows behind them — a long voiceover, following it to the end, and a new voice.
final class StudioController: NSObject {
    let submenu = NSMenu()
    let host: StudioHost
    private var service = StudioMenu.ServiceState.unknown
    private var latestFolder: URL?
    /// A document is being read: the menu row waits and the pill says so.
    private var readingDocument = false
    private lazy var follower = VoiceoverFollower(
        source: VoiceoverFollower.Source(voiceover: { [client = host.client] in try await client.voiceover(id: $0) },
                                         voiceovers: { [client = host.client] in try await client.voiceovers() }),
        onChange: { [weak self] in
            self?.render()
            if self?.followingVoiceover == false { self?.host.workEnded() }
        },
        onFinish: { [weak self] job in
            self?.refreshFolder()
            self?.presentFinish(job)
        })
    private lazy var designer = VoiceDesigner(host: host)

    init(host: StudioHost) {
        self.host = host
        super.init()
        submenu.autoenablesItems = false
    }

    /// A voice design is running or its takes are being reviewed.
    var designing: Bool { designer.running }

    /// A voiceover the app follows has not reached a terminal state.
    var followingVoiceover: Bool { follower.job.map { !$0.status.isTerminal } ?? false }

    // MARK: menu

    func render() {
        let folderExists = latestFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let rows = StudioMenu.rows(
            service: service, installing: host.installing(), job: follower.job,
            serviceWaiting: follower.serviceWaiting, hasOutputFolder: folderExists,
            readingDocument: readingDocument)
        MenuRenderer.fill(submenu, rows: rows, target: self) { action in (#selector(choose(_:)), action) }
    }

    /// The daemon's /status arrived (or failed): redraw, look for the latest
    /// voiceover's folder, and pick up a voiceover already running.
    func statusChanged(_ new: DaemonStatus?) {
        service = new.map { .answered($0) } ?? .unreachable
        if new != nil { follower.serviceAnswered() }
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
        case .createVoice: designer.start()
        case .pickVoice, .pickDictationKey, .pickSpeakKey, .copyDictation, .pasteLastDictation: break
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

    /// "Voiceover ready" with Show in Finder / Play / OK, or why it failed.
    private func presentFinish(_ finished: ProduceJob) {
        guard let (title, text) = ProduceText.finishAlert(finished) else { return }
        guard let path = finished.outputPath else {
            _ = host.alert(title, text, ["OK"])
            return
        }
        let url = URL(fileURLWithPath: path)
        switch host.alert(title, text, ["Show in Finder", "Play", "OK"]) {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertSecondButtonReturn:
            guard let wav = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                _ = host.alert("Couldn't play the voiceover", "The file could not be opened. It may have been moved.", ["OK"])
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
                _ = self.host.alert("The ox-say service isn't answering", "Try again in a moment.", ["OK"])
                return
            }
            let choices = StudioMenu.voiceChoices(voices: voices, russianPick: self.host.russianVoicePick())
            let first = ReviewSheet.Result(title: StudioMenu.defaultTitle(fileName: file.lastPathComponent), script: script,
                                           format: ProduceFormat.allCases[0], voice: choices.names[choices.selected])
            // A start the daemon refuses reopens the sheet with the person's text, not the first cleaning.
            let started = await ReviewRetry.run(first, review: { ReviewSheet(draft: $0, voiceNames: choices.names).run() },
                start: { [client = self.host.client] draft in
                    try await client.startVoiceover(script: draft.script, title: draft.title, voice: draft.voice, format: draft.format)
                },
                failed: { error in
                    _ = self.host.alert("Couldn't start the voiceover", Self.plain(error) + " Your text is kept in the next window.", ["OK"])
                })
            if let started { self.follower.follow(started) }
        }
    }

    /// The cleaned text of the document, or nil after telling the person why there is none.
    private func readScript(_ file: URL) async -> String? {
        readingDocument = true
        render()
        host.pill("Reading the document…")
        defer {
            readingDocument = false
            render()
            host.pill(nil)
        }
        do {
            let read = try await DocumentReader.readScript(file)
            if read.script.isEmpty { _ = host.alert("Nothing to read", read.emptyMessage, ["OK"]) }
            return read.script.isEmpty ? nil : read.script
        } catch {
            let why = (error as? DocumentError)?.description ?? "The file could not be opened."
            _ = host.alert("Couldn't read that file", why, ["OK"])
            return nil
        }
    }

    private func stopVoiceover() {
        guard let job = follower.job else { return }
        let sure = host.alert("Stop this voiceover?", "ox-say stops after the part it is working on. What is already made is not turned into a finished file.",
                              ["Stop Voiceover", "Keep Going"])
        guard sure == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.host.client.stopVoiceover(id: job.id)
            } catch {
                _ = self?.host.alert("Couldn't stop the voiceover", Self.plain(error), ["OK"])
            }
        }
    }

    private func continueOnBattery() {
        guard let job = follower.job else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.host.client.continueOnBattery(id: job.id)
            } catch {
                _ = self?.host.alert("Couldn't continue the voiceover", Self.plain(error), ["OK"])
            }
        }
    }

    private func openFolder() {
        if let latestFolder { NSWorkspace.shared.open(latestFolder) }
    }

    /// An error as the person should read it.
    static func plain(_ error: Error) -> String {
        (error as? StudioError)?.description ?? "Something went wrong. Try again."
    }
}
