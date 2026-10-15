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
}

/// The Studio submenu: draws the rows StudioMenu decides, and runs the three
/// flows behind them — a long voiceover, following it to the end, and a new voice.
final class StudioController: NSObject {
    /// Polls in a row that may fail (the daemon restarting) before the app stops following a voiceover.
    static let maxPollFailures = 12

    let submenu = NSMenu()
    let host: StudioHost
    private var status: DaemonStatus?
    private var job: ProduceJob?
    private var latestFolder: URL?
    private var polling: Task<Void, Never>?
    private lazy var designer = VoiceDesigner(host: host)

    init(host: StudioHost) {
        self.host = host
        super.init()
        submenu.autoenablesItems = false
    }

    // MARK: menu

    func render() {
        let folderExists = latestFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let rows = StudioMenu.rows(
            status: status,
            installAttempted: UserDefaults.standard.bool(forKey: StudioMenu.installAttemptedKey),
            installing: host.installing(), job: job, hasOutputFolder: folderExists)
        MenuRenderer.fill(submenu, rows: rows, target: self) { action in (#selector(choose(_:)), action) }
    }

    /// The daemon's /status arrived (or failed): redraw, and look for the latest voiceover's folder.
    func statusChanged(_ new: DaemonStatus?) {
        status = new
        if new?.studioAvailable == true {
            UserDefaults.standard.removeObject(forKey: StudioMenu.installAttemptedKey)
            refreshFolder()
        }
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
        case .pickVoice, .pickDictationKey, .pickSpeakKey: break
        }
    }

    // MARK: following a voiceover

    /// On launch: a voiceover that was running when the app last quit is still the daemon's.
    func pickUpRunningVoiceover() {
        Task { @MainActor [weak self] in
            guard let self, let jobs = try? await self.host.client.voiceovers(),
                  let running = jobs.first(where: { !$0.status.isTerminal }) else { return }
            self.follow(running)
        }
    }

    private func follow(_ started: ProduceJob) {
        job = started
        render()
        polling?.cancel()
        let id = started.id
        polling = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ProduceText.pollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                do {
                    let latest = try await self.host.client.voiceover(id: id)
                    failures = 0
                    self.job = latest
                    self.render()
                    if !ProduceText.shouldKeepPolling(latest) {
                        self.refreshFolder()
                        self.presentFinish(latest)
                        return
                    }
                } catch StudioError.refused(status: 404, _) {
                    self.forgetJob()
                    return
                } catch {
                    failures += 1
                    if failures >= Self.maxPollFailures {
                        self.forgetJob()
                        self.host.notify("Lost contact with the voiceover. Check the ox-say service.")
                        return
                    }
                }
            }
        }
    }

    private func forgetJob() {
        job = nil
        render()
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
        guard let file = StudioForms.chooseTextFile() else { return }
        guard let script = try? String(contentsOf: file, encoding: .utf8) else {
            _ = host.alert("Couldn't read that file", "Choose a plain text or Markdown file saved as UTF-8.", ["OK"])
            return
        }
        if let problem = ProduceRequest.scriptProblem(script) {
            _ = host.alert("This file can't be voiced", problem, ["OK"])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let voices = try? await self.host.speech.voices() else {
                _ = self.host.alert("The ox-say service isn't answering", "Try again in a moment.", ["OK"])
                return
            }
            let choices = StudioMenu.voiceChoices(voices: voices, russianPick: self.host.russianVoicePick())
            guard let form = StudioForms.voiceoverForm(defaultTitle: StudioMenu.defaultTitle(fileName: file.lastPathComponent),
                                                      choices: choices) else { return }
            do {
                let started = try await self.host.client.startVoiceover(script: script, title: form.title,
                                                                         voice: form.voice, format: form.format)
                self.follow(started)
            } catch {
                _ = self.host.alert("Couldn't start the voiceover", Self.plain(error), ["OK"])
            }
        }
    }

    private func stopVoiceover() {
        guard let job else { return }
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
        guard let job else { return }
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
