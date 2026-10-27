import AppKit
import AVFoundation
import DictationCore
import os

/// What the meeting feature needs of the app around it; closures, so it never
/// reaches into AppDelegate.
struct MeetingHost {
    var client: StudioClient
    var defaults: UserDefaults
    /// A modal alert over every app; returns the pressed button.
    var alert: (_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse
    /// A short message in the status line.
    var notify: (String) -> Void
    /// The recording started or stopped: redraw the status icon, and let a held version handshake run.
    var recordingChanged: () -> Void
    var daemonStatus: () -> DaemonStatus?
}

/// What the app holds of the meeting feature, whatever the macOS version.
protocol MeetingFeature: AnyObject {
    var submenu: NSMenu { get }
    var isRecording: Bool { get }
    func daemonStatusChanged()
    func menuWillOpen()
    /// Closes a recording in progress and hands it to the daemon; bounded, for quit.
    func stopForQuit()
}

/// macOS before 14.2 has no process tap: the menu says so and nothing records.
final class UnsupportedMeetings: MeetingFeature {
    let submenu = NSMenu()
    var isRecording: Bool { false }

    init() {
        submenu.autoenablesItems = false
        let state = MeetingMenuState(supported: false, recordingElapsed: nil, notes: NotesStatus(), autoStart: false, retention: .month)
        MenuRenderer.fill(submenu, rows: MeetingMenu.rows(state, text: { $0.text }), target: self) { _ in (#selector(noop), 0) }
    }

    @objc private func noop() {}
    func daemonStatusChanged() {}
    func menuWillOpen() {}
    func stopForQuit() {}
}

@available(macOS 14.2, *)
final class MeetingController: NSObject, MeetingFeature {
    /// What was already said during one recording: each is said once.
    private enum Told { case silentTap, noSystemAudio, systemAudioStart }

    let submenu = NSMenu()
    private let host: MeetingHost
    private let recorder = MeetingRecorder()
    private let badge = MeetingBadge()
    private let watcher = CallWatcher()
    private let notifier = MeetingNotifier()
    private let exporter: MeetingExporter
    private let log = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "meeting")
    private var current: (info: MeetingInfo, origin: CallTracker.Origin)?
    private var tick: Timer?
    private var tracking: Set<String> = []
    private var retentionPushed = false
    private var notesWereAvailable = false
    private var recent: [MeetingMenuRecent] = []
    private var starting = false
    private var told: Set<Told> = []
    /// Since when some other process has been playing audio without a break (nil = none is).
    private var playingSince: Date?
    private var playingPolledAt = Date.distantPast
    private var lastSource = ""
    private var sleepObserver: NSObjectProtocol?

    var isRecording: Bool { current != nil }

    init(host: MeetingHost) {
        self.host = host
        self.exporter = MeetingExporter(defaults: host.defaults)
        super.init()
        submenu.autoenablesItems = false
        notifier.install()
        recorder.onSystemAudioFailed = { [weak self] why in
            self?.told.insert(.systemAudioStart)
            self?.host.notify(L10nKey.noticeMeetingTapLost.text(why))
        }
        recorder.onMicrophoneFailed = { [weak self] why in self?.host.notify(L10nKey.noticeMeetingMicLost.text(why)) }
        badge.onStop = { [weak self] in self?.stop() }
        badge.onDontRecord = { [weak self] in self?.dontRecordThisOne() }
        badge.onRecord = { [weak self] in
            self?.badge.hide()
            self?.start(origin: .manual, source: self?.lastSource ?? "")
        }
        badge.onNotNow = { [weak self] in
            self?.watcher.decline()
            self?.badge.hide()
        }
        badge.onCopyConsent = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(L10nKey.meetingConsentPhrase.text, forType: .string)
        }
        watcher.recording = { [weak self] in self?.current?.origin }
        watcher.themActive = { [weak self] in self?.recorder.themActive ?? false }
        watcher.onTick = { [weak self] tick in self?.observe(tick) }
        // A closed lid ends the recording cleanly: the audio devices disappear under it, and what was recorded is
        // handed to the daemon instead of waiting for its stale-recording sweep.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in self?.stopForSleep() }
        applyAutoStart()
        reconcile()
        render()
    }

    // MARK: menu

    func menuWillOpen() {
        render()
        // The meetings whose speakers can be named, newest first; the daemon is asked each time the menu opens.
        Task { @MainActor in
            guard let list = try? await host.client.meetings() else { return }
            recent = MeetingMenuRecent.from(list)
            render()
        }
    }

    func daemonStatusChanged() {
        if !retentionPushed, host.daemonStatus() != nil {
            retentionPushed = true
            let days = MeetingSettings.retention(host.defaults).days
            Task { try? await host.client.setMeetingRetention(days: days) }
        }
        // The notes model just arrived: meetings that waited for it get their notes.
        let available = host.daemonStatus()?.notes.available ?? false
        if available, !notesWereAvailable { reconcile() }
        notesWereAvailable = available
        render()
    }

    private func render() {
        let state = MeetingMenuState(supported: true, recordingElapsed: current == nil ? nil : recorder.elapsed,
                                     notes: host.daemonStatus()?.notes ?? NotesStatus(),
                                     autoStart: MeetingSettings.autoStart(host.defaults),
                                     retention: MeetingSettings.retention(host.defaults), recent: recent)
        MenuRenderer.fill(submenu, rows: MeetingMenu.rows(state, text: { $0.text }), target: self) { action in
            (#selector(choose(_:)), action)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .startMeeting: start(origin: .manual, source: "manual")
        case .stopMeeting: stop()
        case .installNotesModel: installModel()
        case .openMeetingsFolder: openFolder()
        case .chooseMeetingsFolder: chooseFolder()
        case .setMeetingName: askName()
        case .toggleMeetingAutoStart:
            MeetingSettings.setAutoStart(!MeetingSettings.autoStart(host.defaults), host.defaults)
            applyAutoStart()
        case .pickMeetingRetention(let days):
            let pick = MeetingRetention(rawValue: days) ?? .month
            MeetingSettings.setRetention(pick, host.defaults)
            Task { try? await host.client.setMeetingRetention(days: pick.days) }
        case .editSpeakers(let id): editSpeakers(id)
        case .retryVoices(let id): retryVoices(id)
        default: break
        }
        render()
    }

    // MARK: recording

    private func start(origin: CallTracker.Origin, source: String) {
        guard current == nil, !starting else { return }
        if origin == .auto, !explainedAndAllowed() { return }
        // Before a meeting exists in the daemon: a missing microphone permission leaves nothing to clean up.
        do { try MeetingRecorder.checkMicrophone() } catch {
            host.notify(L10nKey.noticeMeetingStartFailed.text("\(error)"))
            return
        }
        starting = true
        let defaults = host.defaults
        let me = MeetingSettings.displayName(defaults, fallback: NSFullUserName())
        let title = MeetingLimits.title(forSource: source)
        Task { @MainActor in
            defer { starting = false }
            var created: MeetingInfo?
            do {
                let info = try await host.client.createMeeting(title: title, source: source, me: me,
                                                               them: L10nKey.meetingLabelOther.text,
                                                               speaker: L10nKey.meetingLabelSpeaker.text,
                                                               echoRisk: MeetingRecorder.echoRisk())
                created = info
                guard let dir = info.dir else { throw StudioError.badResponse }
                try recorder.start(into: URL(fileURLWithPath: dir, isDirectory: true))
                current = (info, origin)
                told = []
                playingSince = nil
                playingPolledAt = .distantPast
                badge.showRecording(auto: origin == .auto, elapsed: 0)
                startTick()
                host.recordingChanged()
            } catch {
                host.notify(L10nKey.noticeMeetingStartFailed.text("\(error)"))
                // A meeting the daemon opened but the recorder never started would sit as "recording".
                if let created, current == nil { _ = try? await host.client.finishMeeting(id: created.id) }
            }
            render()
        }
    }

    private func startTick() {
        // .common: the cap, the disk check and the silent-tap guard keep running while a menu is open.
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(refreshBadge), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    @objc private func refreshBadge() {
        guard current != nil else { return }
        let l = recorder.levels
        badge.update(elapsed: recorder.elapsed, me: l.me, them: l.them)
        // The first failed write stops the recording and says so (#247): the rest would be a file with holes.
        if recorder.writeFailed {
            host.notify(L10nKey.noticeMeetingDiskFull.text)
            stop()
            return
        }
        if MeetingLimits.reachedCap(elapsed: recorder.elapsed) {
            host.notify(L10nKey.noticeMeetingCapReached.text)
            stop()
            return
        }
        checkSystemAudio()
    }

    /// Said while the call is still on, not only afterwards: the tap can show as allowed and deliver only zeros
    /// (P0a, 2026-10-26), or the other side can stay silent for 20 s.
    private func checkSystemAudio() {
        pollPlaying()
        let stats = recorder.tapStats
        let sample = SystemAudioGuard.Sample(callbacks: stats.callbacks, peak: stats.peak, elapsed: recorder.elapsed,
                                             playingFor: playingSince.map { Date().timeIntervalSince($0) } ?? 0,
                                             heardLoud: recorder.heardTheOtherSide)
        switch SystemAudioGuard.assess(sample) {
        case .silentTap:
            if told.insert(.silentTap).inserted { tellSilentTap() }
        case .noCallbacks:
            // A tap that failed to start has been said already.
            if !told.contains(.systemAudioStart), told.insert(.noSystemAudio).inserted {
                host.notify(L10nKey.noticeMeetingNoSystemAudio.text)
            }
        case .otherSideQuiet:
            if !told.contains(.silentTap), told.insert(.noSystemAudio).inserted {
                host.notify(L10nKey.noticeMeetingNoSystemAudio.text)
            }
        case .waiting, .fine:
            break
        }
    }

    /// Once a second: is some other process playing audio, and since when. A CoreAudio error keeps the last answer.
    private func pollPlaying() {
        guard Date().timeIntervalSince(playingPolledAt) >= 1 else { return }
        playingPolledAt = Date()
        let me = getpid()
        guard let processes = CoreAudioProps.audioProcesses() else { return }
        if processes.contains(where: { $0.runningOutput && $0.pid != me }) {
            if playingSince == nil { playingSince = Date() }
        } else {
            playingSince = nil
        }
    }

    private func tellSilentTap() {
        let sentence = L10nKey.noticeMeetingTapSilent.text
        host.notify(sentence)
        // Out of the timer callback: the alert is modal.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pressed = self.host.alert(L10nKey.meetingTapSilentTitle.text, sentence,
                                          [L10nKey.meetingTapSilentOpen.text, L10nKey.meetingTapSilentLater.text])
            if pressed == .alertFirstButtonReturn, let url = URL(string: SystemAudioGuard.settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func stop() {
        guard let (info, _) = current else { return }
        current = nil
        tick?.invalidate()
        tick = nil
        logSummary(recorder.stop(), id: info.id)
        badge.hide()
        host.recordingChanged()
        Task { @MainActor in
            do { _ = try await host.client.finishMeeting(id: info.id) } catch {
                host.notify(L10nKey.noticeMeetingFailed.text("\(error)"))
            }
            track(info.id)
            render()
        }
    }

    private func stopForSleep() {
        guard current != nil else { return }
        host.notify(L10nKey.noticeMeetingSlept.text)
        stop()
    }

    func stopForQuit() {
        guard let (info, _) = current else { return }
        current = nil
        tick?.invalidate()
        tick = nil
        logSummary(recorder.stop(), id: info.id)
        let done = DispatchSemaphore(value: 0)
        let client = host.client
        // Detached: the app's main thread waits below, and a task that inherited the main actor would wait for it.
        Task.detached {
            _ = try? await client.finishMeeting(id: info.id, timeout: 2)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    /// How the clock was handled: counts only, never audio or text (#247, #251).
    private func logSummary(_ s: MeetingRecorder.Summary, id: String) {
        log.info("""
        meeting recorded: me dropped=\(s.meDropped, privacy: .public) padded=\(s.mePadded, privacy: .public) \
        them dropped=\(s.themDropped, privacy: .public) padded=\(s.themPadded, privacy: .public) \
        failedWrites=\(s.failedWrites, privacy: .public) \
        micConversions failed=\(s.micConversions.failed, privacy: .public) empty=\(s.micConversions.empty, privacy: .public) \
        tapConversions failed=\(s.tapConversions.failed, privacy: .public) empty=\(s.tapConversions.empty, privacy: .public)
        """)
    }

    private func dontRecordThisOne() {
        watcher.decline()
        if current?.origin == .auto { stop() } else { badge.hide() }
    }

    // MARK: detection

    private func applyAutoStart() {
        if MeetingSettings.autoStart(host.defaults) { watcher.start() } else { watcher.stop() }
    }

    /// One poll of the call watcher: the tracker has decided (offer, start, stop); the notices it could not.
    private func observe(_ tick: CallWatcher.Tick) {
        if let call = tick.call { lastSource = call.source }
        if tick.browserDenied { host.notify(L10nKey.noticeMeetingBrowserDenied.text) }
        if tick.browserNeedsPermission { host.notify(L10nKey.noticeMeetingBrowserPending.text) }
        switch tick.action {
        case .nothing: break
        case .callStarted(let source):
            if MeetingSettings.autoStart(host.defaults), CallDetector.autoStartSources.contains(source) {
                start(origin: .auto, source: source)
            } else {
                badge.showPrompt(source: source)
            }
        case .stopRecording:
            stop()
        }
    }

    /// The one-time explanation and consent reminder before the first
    /// automatic recording. "Only When I Choose" turns auto-start off and the
    /// call is offered in the badge instead.
    private func explainedAndAllowed() -> Bool {
        if MeetingSettings.explained(host.defaults) { return true }
        let pressed = host.alert(L10nKey.meetingExplainTitle.text, L10nKey.meetingExplainBody.text,
                                 [L10nKey.meetingExplainOK.text, L10nKey.meetingExplainManual.text])
        MeetingSettings.setExplained(host.defaults)
        // Creating the folder now makes macOS ask for Documents access here, with the
        // explanation on screen, not at the end of the first call.
        try? FileManager.default.createDirectory(at: MeetingSettings.folder(host.defaults), withIntermediateDirectories: true)
        if pressed == .alertFirstButtonReturn { return true }
        MeetingSettings.setAutoStart(false, host.defaults)
        applyAutoStart()
        badge.showPrompt(source: lastSource)
        return false
    }

    // MARK: after the call

    /// Follow a meeting through the daemon's steps, then copy it to the notes folder.
    private func track(_ id: String) {
        guard tracking.insert(id).inserted else { return }
        Task { @MainActor in
            defer { tracking.remove(id) }
            let deadline = Date().addingTimeInterval(4 * 3600)
            while Date() < deadline {
                if let info = try? await host.client.meeting(id: id), info.settled {
                    await finished(id: id, status: info)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func finished(id: String, status: MeetingInfo) async {
        guard let info = try? await host.client.meeting(id: id, withTexts: true) else { return }
        if info.heardNoSystemAudio { host.notify(L10nKey.noticeMeetingNoSystemAudio.text) }
        switch info.status {
        case .failed:
            host.notify(L10nKey.noticeMeetingFailed.text(info.error ?? ""))
        case .transcribed where info.notesPending == "model_missing":
            // Not copied yet: the folder gets the transcript and the notes together, once the model is there.
            host.notify(L10nKey.noticeMeetingNotesPending.text)
        case .done, .transcribed:
            let folder = export(info)
            if info.status == .done {
                // A copy that failed has said so; "ready" would contradict it.
                if folder.failed { return }
                ready(folder: folder.dir)
            } else if let error = info.error {
                host.notify(L10nKey.noticeMeetingFailed.text(error))
            }
        default: break
        }
    }

    /// "Meeting notes are ready", as a notification that opens the folder; the menu's status line carries the same
    /// words when notifications are not allowed (#251).
    private func ready(folder: URL?) {
        let title = L10nKey.noticeMeetingReady.text
        notifier.post(title: title, folder: folder) { [weak self] delivered in
            guard !delivered else { return }
            DispatchQueue.main.async { self?.host.notify(title) }
        }
    }

    /// Copies the meeting into the notes folder through the ledger (`MeetingExporter`) and says what the user must
    /// hear: a copy left alone, a copy that could not be made.
    @discardableResult
    private func export(_ info: MeetingInfo) -> (dir: URL?, failed: Bool, told: Bool) {
        let outcome = exporter.export(info)
        switch outcome {
        case .written(let dir), .refreshed(let dir): return (dir, false, false)
        case .keptEdited(let dir):
            host.notify(L10nKey.noticeMeetingCopyKept.text)
            return (dir, false, true)
        case .alreadyExported: return (nil, false, false)
        case .failed(let why):
            host.notify(L10nKey.noticeMeetingFailed.text(why))
            return (nil, true, true)
        }
    }

    /// At launch: follow meetings the daemon is still working on, and copy the
    /// ones that finished while the app was not running.
    private func reconcile() {
        Task { @MainActor in
            guard let list = try? await host.client.meetings() else { return }
            for m in list.prefix(20) {
                switch m.status {
                case .queued, .transcribing, .summarizing: track(m.id)
                case .done:
                    if !MeetingSettings.exported(host.defaults).contains(m.id) { track(m.id) }
                case .transcribed where m.notesPending == "model_missing":
                    if host.daemonStatus()?.notes.available == true {
                        try? await host.client.retryMeetingNotes(id: m.id)
                        track(m.id)
                    }
                case .transcribed:
                    if !MeetingSettings.exported(host.defaults).contains(m.id) { track(m.id) }
                default: break
                }
            }
        }
    }

    // MARK: speakers

    private func editSpeakers(_ id: String) {
        Task { @MainActor in
            do {
                var state = try await host.client.speakers(id: id)
                let title = recent.first(where: { $0.id == id })?.title ?? ""
                while let draft = SpeakersPrompt.ask(title: title, state: state) {
                    let edits = draft.edits(against: state)
                    if edits.isEmpty { return }
                    let wasOffer = state.offersSplit
                    state = try await host.client.editSpeakers(id: id, edits: edits)
                    MeetingSettings.setExportStale(id, true, host.defaults)
                    // Decide from the daemon's answer, never from the shape of the edit.
                    if state.notesQueued {
                        track(id)
                        host.notify(L10nKey.noticeSpeakersSaved.text)
                    } else {
                        // A copy left alone or not made has said so; "saved" would bury that sentence.
                        var said = false
                        if let info = try? await host.client.meeting(id: id, withTexts: true) { said = export(info).told }
                        if !said { host.notify(L10nKey.noticeSpeakersNamesSaved.text) }
                    }
                    if !(wasOffer && !state.offersSplit) { return }
                }
            } catch {
                host.notify(L10nKey.speakersFailed.text("\(error)"))
            }
        }
    }

    private func retryVoices(_ id: String) {
        Task { @MainActor in
            do {
                try await host.client.retryMeetingVoices(id: id)
                // The transcript is written again: the copy in the notes folder is of the old one.
                MeetingSettings.setExportStale(id, true, host.defaults)
                track(id)
            } catch {
                host.notify(L10nKey.speakersFailed.text("\(error)"))
            }
        }
    }

    // MARK: settings

    private func openFolder() {
        let folder = MeetingSettings.folder(host.defaults)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = MeetingSettings.folder(host.defaults)
        panel.prompt = L10nKey.menuMeetingChooseFolder.text
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { MeetingSettings.setFolder(url, host.defaults) }
    }

    private func askName() {
        let alert = NSAlert()
        alert.messageText = L10nKey.menuMeetingYourName.text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = MeetingSettings.displayName(host.defaults, fallback: NSFullUserName())
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { MeetingSettings.setDisplayName(field.stringValue, host.defaults) }
    }

    private func installModel() {
        Task { @MainActor in
            do { try await host.client.installNotesModel() } catch { host.notify("\(error)") }
            render()
        }
    }
}
