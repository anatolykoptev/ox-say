import AppKit
import DictationCore

/// What the Studio features need from the app around them; closures, so the
/// studio code never reaches into AppDelegate.
struct StudioHost {
    var client: StudioClient
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
    /// The New Voiceover menu row: the window opens on Озвучка, where the text, a document and the voice are chosen.
    var openSpeak: () -> Void
    /// The Stop row: the window opens on that voiceover, where stopping asks for its confirmation (never an alert over every app).
    var openSpeakProject: (_ id: String) -> Void
    /// What the window and the app show at this moment (a finished voiceover is announced unless it is on screen).
    var windowShown: () -> ShownWindow
}

/// The Studio submenu: draws the rows StudioMenu decides and runs what they do — continue a voiceover on battery, open
/// its folder, follow it to the end. A new voiceover, a stop and a new voice open the window (Озвучка, the describe-a-voice
/// sheet); a finished voiceover is told by a notification and by its row there, never by an alert.
final class StudioController: NSObject {
    let submenu = NSMenu()
    let host: StudioHost
    private var service = StudioMenu.ServiceState.unknown
    private var latestFolder: URL?
    /// The voiceover being followed; the window's Озвучка page starts and reads the same one.
    let voiceover: VoiceoverService
    /// Describe a voice: the window's sheet drives it, the menu row opens that sheet.
    lazy var designer = VoiceDesigner(host: host)

    init(host: StudioHost) {
        self.host = host
        voiceover = VoiceoverService(client: host.client, windowShown: host.windowShown)
        super.init()
        submenu.autoenablesItems = false
        voiceover.observe(
            onChange: { [weak self] in
                self?.render()
                if self?.voiceover.following == false { self?.host.workEnded() }
            },
            onFinish: { [weak self] _ in self?.refreshFolder() })
    }

    /// A voice design is running or its takes are being reviewed.
    var designing: Bool { designer.running }

    // MARK: menu

    func render() {
        let folderExists = latestFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let rows = StudioMenu.rows(
            service: service, installing: host.installing(), job: voiceover.job,
            serviceWaiting: voiceover.serviceWaiting, hasOutputFolder: folderExists)
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
        case .newVoiceover: host.openSpeak()
        case .stopVoiceover: if let job = voiceover.job { host.openSpeakProject(job.id) }
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

    // MARK: flows

    /// «Continue on Battery Power» goes straight to the daemon: the person already asked. A refusal is said on the status line.
    private func continueOnBattery() {
        guard voiceover.job != nil else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.voiceover.continueOnBattery()
            } catch {
                self?.host.notify(StudioError.plain(error))
            }
        }
    }

    private func openFolder() {
        if let latestFolder { NSWorkspace.shared.open(latestFolder) }
    }

}
