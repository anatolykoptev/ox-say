import AppKit
import AVFoundation
import DictationCore
import os

/// What the meeting feature needs of the app around it; closures, so it never
/// reaches into AppDelegate.
struct MeetingHost {
    var client: StudioClient
    var defaults: UserDefaults
    /// Told whether a call is on, for the dictation sound mode (it must not lower a call).
    var callActivity: CallActivity
    /// A modal alert over every app; returns the pressed button.
    var alert: (_ title: String, _ text: String, _ buttons: [String]) -> NSApplication.ModalResponse
    /// A short message in the status line.
    var notify: (String) -> Void
    /// The recording started or stopped: redraw the status icon, and let a held version handshake run.
    var recordingChanged: () -> Void
    var daemonStatus: () -> DaemonStatus?
    /// An update is being installed: a recording started now would be ended by the relaunch.
    var updateInstalling: () -> Bool
}

/// What the app holds of the meeting feature, whatever the macOS version.
@MainActor
protocol MeetingFeature: AnyObject {
    var submenu: NSMenu { get }
    var isRecording: Bool { get }
    func daemonStatusChanged()
    func menuWillOpen()
    /// Closes a recording in progress and hands it to the daemon; bounded, for quit.
    func stopForQuit()
    /// Seconds into the recording that runs now; nil when none does. The main window's bar reads this.
    var recordingElapsed: TimeInterval? { get }
    /// The menu's "Record Meeting" and "Stop Recording" paths, for the main window's buttons.
    func startRecording()
    func stop()
    /// The speakers edit of the main window: saved and followed up exactly as the menu's panel does.
    func saveSpeakers(id: String, edits: SpeakerEdits) async throws -> SpeakersState
    /// The main window's "find voices again".
    func requestVoicesAgain(id: String) async throws
    /// The main window's "try again" for notes that could not be written: asked for again, then followed to the end.
    func retryNotes(id: String) async throws
    /// The main window renamed a meeting: the copy in the notes folder is of the old title.
    func rename(id: String, title: String) async throws
    /// Meetings were switched off: stops a recording, the call watcher and everything else that runs.
    func shutDown()
    /// The global call mode (or a per-app pick) changed in the main window: the watcher and the menu follow.
    func settingsChanged()
}

/// macOS before 14.2 has no process tap: the menu says so and nothing records.
@MainActor
final class UnsupportedMeetings: MeetingFeature {
    let submenu = NSMenu()
    var isRecording: Bool { false }

    init() {
        submenu.autoenablesItems = false
        let state = MeetingMenuState(supported: false, recordingElapsed: nil, notes: NotesStatus(), callMode: .ask, retention: .month)
        MenuRenderer.fill(submenu, rows: MeetingMenu.rows(state, text: { $0.text }), target: self) { _ in (#selector(noop), 0) }
    }

    @objc private func noop() {}
    func daemonStatusChanged() {}
    func menuWillOpen() {}
    func stopForQuit() {}
    var recordingElapsed: TimeInterval? { nil }
    func startRecording() {}
    func stop() {}
    func saveSpeakers(id: String, edits: SpeakerEdits) async throws -> SpeakersState { throw MeetingFeatureError.needsNewerMacOS }
    func requestVoicesAgain(id: String) async throws { throw MeetingFeatureError.needsNewerMacOS }
    func retryNotes(id: String) async throws { throw MeetingFeatureError.needsNewerMacOS }
    func rename(id: String, title: String) async throws { throw MeetingFeatureError.needsNewerMacOS }
    func shutDown() {}
    func settingsChanged() {}
}

@available(macOS 14.2, *)
@MainActor
final class MeetingController: NSObject, MeetingFeature {
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
    /// Meetings were switched off: a start still waiting for the daemon must not begin recording afterwards.
    private var isShutDown = false
    /// The tick's decisions (stop, say) live in DictationCore; this carries them out.
    private var monitor = RecordingMonitor()
    /// Since when some other process has been playing audio without a break (nil = none is).
    private var playingSince: Date?
    private var playingPolledAt = Date.distantPast
    private var lastSource = ""
    private var offerLife = OfferLifetime()
    private var sleepObserver: NSObjectProtocol?

    var isRecording: Bool { current != nil }
    var recordingElapsed: TimeInterval? { current == nil ? nil : recorder.elapsed }

    func startRecording() { start(origin: .manual, source: "manual") }

    init(host: MeetingHost) {
        self.host = host
        self.exporter = MeetingExporter(defaults: host.defaults)
        super.init()
        submenu.autoenablesItems = false
        notifier.install()
        recorder.onSystemAudioFailed = { [weak self] in
            self?.monitor.systemAudioFailed = true
            self?.host.notify(L10nKey.noticeMeetingTapLost.text)
        }
        recorder.onSystemAudioRecovered = { [weak self] in
            self?.monitor.systemAudioFailed = false
            self?.host.notify(L10nKey.noticeMeetingTapRecovered.text)
        }
        recorder.onMicrophoneFailed = { [weak self] in self?.host.notify(L10nKey.noticeMeetingMicLost.text) }
        recorder.onMicrophoneRecovered = { [weak self] in self?.host.notify(L10nKey.noticeMeetingMicRecovered.text) }
        badge.onStop = { [weak self] in self?.stop() }
        badge.onDontRecord = { [weak self] in self?.dontRecordThisOne() }
        badge.onRecord = { [weak self] in
            self?.badge.hide()
            self?.start(origin: .manual, source: self?.lastSource ?? "", offered: true)
        }
        badge.onNotNow = { [weak self] in
            self?.watcher.decline()
            self?.badge.hide()
        }
        badge.onDontAsk = { [weak self] in self?.dontAskForThisApp() }
        badge.onBrowserAllow = { [weak self] in self?.allowBrowserAutomation() }
        badge.onBrowserNotNow = { [weak self] in self?.skipBrowserAutomation() }
        badge.onCopyConsent = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(L10nKey.meetingConsentPhrase.text, forType: .string)
        }
        watcher.recording = { [weak self] in self?.current?.origin }
        watcher.themActive = { [weak self] in self?.recorder.themActive ?? false }
        watcher.modeFor = { [weak self] source in
            guard let self else { return CallPolicy.defaultMode(source) }
            return CallPolicy.effectiveMode(for: source, global: MeetingSettings.callMode(self.host.defaults),
                                            picked: CallPolicy.pickedMode(for: source, self.host.defaults))
        }
        watcher.onTick = { [weak self] tick in self?.observe(tick) }
        // A closed lid ends the recording cleanly: the audio devices disappear under it, and what was recorded is
        // handed to the daemon instead of waiting for its stale-recording sweep.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in Task { @MainActor in self?.stopForSleep() } }
        applyCallMode()
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
            // A refusal is logged, not retried on every status poll: the next launch and every retention pick push it again.
            Task {
                do { try await host.client.setMeetingRetention(days: days) } catch {
                    log.error("retention push at launch failed: \(String(describing: error), privacy: .public)")
                }
            }
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
                                     callMode: MeetingSettings.callMode(host.defaults),
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
        case .pickMeetingCallMode(let mode):
            MeetingSettings.setCallMode(mode, host.defaults)
            applyCallMode()
        case .pickMeetingRetention(let days):
            // The daemon first, the app's copy only once it took it; a refusal is said, not swallowed.
            let pick = MeetingRetention(rawValue: days) ?? .month
            Task {
                if let failure = await MeetingSettingsApplier(defaults: host.defaults, client: host.client).apply(.retention(pick)) {
                    host.notify(failure)
                }
                render()
            }
        case .editSpeakers(let id): editSpeakers(id)
        case .retryVoices(let id): retryVoices(id)
        default: break
        }
        render()
    }

    // MARK: recording

    /// `offered`: the user pressed Record on the call prompt — the one-time explanation runs for it like for an
    /// automatic start. A menu "Record a meeting" is her own act and skips it.
    private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {
        guard current == nil, !starting, !isShutDown else { return }
        // An install relaunches the app. A recording started now would be ended by it: automatic starts are offered
        // instead (MeetingPolicy.onCallStarted), a manual one asks the user to wait.
        let installing = host.updateInstalling()
        if origin == .auto, installing { return }
        if origin == .manual, MeetingPolicy.manualStart(installing: installing) == .waitForInstall {
            host.notify(L10nKey.noticeMeetingWaitInstall.text)
            return
        }
        if origin == .auto || offered, !consentReminderAccepted() { return }
        // Before a meeting exists in the daemon: a missing microphone permission leaves nothing to clean up.
        do { try MeetingRecorder.checkMicrophone() } catch {
            host.notify(L10nKey.noticeMeetingStartFailed.text(MeetingErrorText.sentence(error, action: .start)))
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
                // Switched off while the daemon was opening the meeting: close it through the usual path and record nothing.
                if isShutDown {
                    discardEmpty(info.id)
                    return
                }
                guard let dir = info.dir else { throw StudioError.badResponse }
                try recorder.start(into: URL(fileURLWithPath: dir, isDirectory: true))
                current = (info, offered ? .offered : origin)
                syncCallActivity()
                monitor = RecordingMonitor()
                playingSince = nil
                playingPolledAt = .distantPast
                badge.showRecording(auto: origin == .auto, elapsed: 0)
                startTick()
                host.recordingChanged()
            } catch {
                host.notify(L10nKey.noticeMeetingStartFailed.text(MeetingErrorText.sentence(error, action: .start)))
                // A meeting the daemon opened but the recorder never started would sit as "recording".
                if let created, current == nil { discardEmpty(created.id) }
            }
            render()
        }
    }

    /// A meeting the daemon opened that nothing was recorded into would sit as "recording" or, finished, as an empty
    /// row in the window (#270): it is finished and deleted. A task of its own, so a daemon that is slow to let go
    /// does not hold the next start (`starting`) up; what stays behind is logged.
    private func discardEmpty(_ id: String) {
        let client = host.client
        Task {
            let outcome = await EmptyMeetingCleanup.discard(
                finish: { _ = try await client.finishMeeting(id: id) },
                delete: { try await client.deleteMeeting(id: id) },
                sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
            if case .left(let why) = outcome { log.error("empty meeting \(id, privacy: .public) was not deleted: \(why, privacy: .public)") }
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
        pollPlaying()
        let stats = recorder.tapStats
        let tick = RecordingMonitor.Tick(elapsed: recorder.elapsed, writeFailed: recorder.writeFailed,
                                         callbacks: stats.callbacks, peak: stats.peak,
                                         playingFor: playingSince.map { Date().timeIntervalSince($0) } ?? 0,
                                         heardLoud: recorder.heardTheOtherSide, meLoud: l.me > Self.loudMic, dt: 0.25)
        for action in monitor.observe(tick) {
            switch action {
            case .stop(.diskFull):
                host.notify(L10nKey.noticeMeetingDiskFull.text)
                stop()
                return
            case .stop(.cap):
                host.notify(L10nKey.noticeMeetingCapReached.text)
                stop()
                return
            case .say(.tapSilent): tellSilentTap()
            case .say(.noSystemAudio): host.notify(L10nKey.noticeMeetingNoSystemAudio.text)
            }
        }
    }

    /// The microphone counts as loud (somebody on this side is talking) above this RMS, the recorder's own threshold.
    private static let loudMic: Float = 0.003

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

    /// Not a modal alert: a modal mid-call takes the focus and the next stray Return, and a wrong guess (a muted far
    /// side) must cost nothing. The sentence goes to the status line, and — where notifications are allowed — to a
    /// notification whose click opens the System Audio Recording pane.
    private func tellSilentTap() {
        let sentence = L10nKey.noticeMeetingTapSilent.text
        host.notify(sentence)
        notifier.post(title: L10nKey.meetingTapSilentTitle.text, body: sentence, openURL: URL(string: SystemAudioGuard.settingsURL))
    }

    func stop() {
        guard let (info, _) = current else { return }
        current = nil
        syncCallActivity()
        tick?.invalidate()
        tick = nil
        logSummary(recorder.stop(), id: info.id)
        badge.hide()
        applyCallMode()
        host.recordingChanged()
        Task { @MainActor in
            do { _ = try await host.client.finishMeeting(id: info.id) } catch {
                host.notify(L10nKey.noticeMeetingFailed.text(MeetingErrorText.sentence(error, action: .finish)))
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
        syncCallActivity()
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
        tapConversions failed=\(s.tapConversions.failed, privacy: .public) empty=\(s.tapConversions.empty, privacy: .public) \
        tapNilBuffers=\(s.tapNilBuffers, privacy: .public) tapExclusionMissing=\(s.tapExclusionMissing, privacy: .public)
        """)
    }

    private func dontRecordThisOne() {
        watcher.decline()
        if current?.origin == .auto { stop() } else { badge.hide() }
    }

    /// The prompt's quiet third action: "Don't ask for <App>" is the app's per-app "Never ask"
    /// (reversible in Settings), and this call is done asking.
    private func dontAskForThisApp() {
        guard case .prompt(let source) = badge.mode else { return }
        CallPolicy.setMode(.never, for: source, host.defaults)
        watcher.decline()
        badge.hide()
    }

    /// "Allow…" on the Automation badge: the next read is the real one — macOS's own prompt is raised in
    /// context now.
    private func allowBrowserAutomation() {
        guard case .browserConsent(let id) = badge.mode else { return }
        badge.hide()
        watcher.allowBrowserAutomation(id)
    }

    /// "Not now" on the Automation badge: nothing is sent to that browser until it lets the microphone go.
    private func skipBrowserAutomation() {
        guard case .browserConsent(let id) = badge.mode else { return }
        watcher.skipBrowserAutomation(id)
        badge.hide()
    }

    // MARK: detection

    /// Tells the dictation sound mode whether a meeting is being recorded. The call watcher's half is set in `observe`
    /// and cleared when the watcher stops. Limitation: with calls off and nothing recording the watcher does not
    /// run, so a call is not seen; no poller is started just for dictation.
    private func syncCallActivity() { host.callActivity.setRecording(current != nil) }

    private func applyCallMode() {
        let mode = MeetingSettings.callMode(host.defaults)
        // An automatic recording's silence auto-stop needs the watcher even if calls were turned off mid-call.
        if MeetingPolicy.watcherShouldRun(mode: mode, recording: current?.origin) {
            watcher.start()
        } else {
            watcher.stop()
            host.callActivity.setCallSeen(false)
        }
        // Off means no offers: a prompt or consent badge that is still up must not keep asking.
        if !OfferLifetime.offersAllowed(mode: mode) {
            if case .recording = badge.mode {} else { badge.hide() }
        }
    }

    /// One poll of the call watcher: the tracker has decided (offer, start, stop); the notices it could not.
    private func observe(_ tick: CallWatcher.Tick) {
        host.callActivity.setCallSeen(tick.call != nil)
        if let call = tick.call { lastSource = call.source }
        if tick.browserDenied { host.notify(L10nKey.noticeMeetingBrowserDenied.text) }
        if tick.browserNeedsPermission { host.notify(L10nKey.noticeMeetingBrowserPending.text) }
        // The question on the badge outlives neither its call (a dropout of one poll is not the end), nor the
        // browser's hold on the microphone: OfferLifetime decides, this only draws.
        let offer: OfferLifetime.Offer?
        switch badge.mode {
        case .prompt(let source)?: offer = .prompt(source: source)
        case .browserConsent(let id)?: offer = .browserConsent(browser: id)
        default: offer = nil
        }
        if case .hide(let why) = offerLife.verdict(now: Date(), offer: offer, liveSource: tick.call?.source, heldOnly: tick.heldOnly, users: tick.users) {
            badge.hide()
            // Taken down without an answer, about a call that may return: asked about again when it does.
            if why.withdrawsOffer { watcher.offerWithdrawn() }
        }
        // A browser holds the microphone and nobody was asked about Automating it: ask in context before the
        // first Apple Event — unless the badge is already serving a prompt or a recording.
        if let id = tick.browserNeedsConsent, badge.mode == nil { badge.showBrowserConsent(browser: id) }
        switch tick.action {
        case .nothing: break
        case .callStarted(let source):
            switch MeetingPolicy.onCallStarted(source: source, global: MeetingSettings.callMode(host.defaults),
                                               picked: CallPolicy.pickedMode(for: source, host.defaults), installing: host.updateInstalling()) {
            case .start: start(origin: .auto, source: source)
            case .prompt: badge.showPrompt(source: source)
            case .ignore: break
            }
        case .stopRecording:
            stop()
        }
    }

    /// The one-time consent reminder before the first recording that was offered or started automatically:
    /// what is recorded, and to tell the others. It is a reminder only — it never writes the call mode or an
    /// app's pick; "Don't Record" cancels this start and the reminder comes again next time.
    private func consentReminderAccepted() -> Bool {
        if MeetingSettings.explained(host.defaults) { return true }
        let pressed = host.alert(L10nKey.meetingRemindTitle.text,
                                 ConsentReminder.body(retention: MeetingSettings.retention(host.defaults), text: { $0.text }),
                                 [L10nKey.meetingRemindRecord.text, L10nKey.meetingRemindSkip.text])
        guard pressed == .alertFirstButtonReturn else { return false }
        MeetingSettings.setExplained(host.defaults)
        // Creating the folder now makes macOS ask for Documents access here, with the
        // reminder on screen, not at the end of the first call.
        try? FileManager.default.createDirectory(at: MeetingSettings.folder(host.defaults), withIntermediateDirectories: true)
        return true
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
            host.notify(MeetingFailureNotice.announcement(for: info) ?? L10nKey.meetingFailedGeneric.text)
        case .transcribed where info.notesPending == "model_missing":
            // Not copied yet: the folder gets the transcript and the notes together, once the model is there.
            host.notify(L10nKey.noticeMeetingNotesPending.text)
        case .done, .transcribed:
            let folder = export(info)
            if info.status == .done {
                // A copy that failed has said so; "ready" would contradict it.
                if folder.failed { return }
                ready(folder: folder.dir)
            } else if let sentence = MeetingFailureNotice.announcement(for: info) {
                host.notify(sentence)
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
            let notesAvailable = host.daemonStatus()?.notes.available == true
            for m in list.prefix(20) {
                switch Reconcile.action(for: m, exported: MeetingSettings.exported(host.defaults), notesAvailable: notesAvailable,
                                        currentID: current?.info.id) {
                case .skip: break
                case .track: track(m.id)
                case .retryNotesThenTrack:
                    try? await host.client.retryMeetingNotes(id: m.id)
                    track(m.id)
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
                    state = try await saveSpeakers(id: id, edits: edits)
                    if !(wasOffer && !state.offersSplit) { return }
                }
            } catch {
                host.notify(L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .speakers)))
            }
        }
    }

    /// Sends the edits and follows them up. The menu's panel and the main window both come through here.
    func saveSpeakers(id: String, edits: SpeakerEdits) async throws -> SpeakersState {
        let state = try await host.client.editSpeakers(id: id, edits: edits)
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
        return state
    }

    private func retryVoices(_ id: String) {
        Task { @MainActor in
            do { try await requestVoicesAgain(id: id) } catch {
                host.notify(L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .retryVoices)))
            }
        }
    }

    func requestVoicesAgain(id: String) async throws {
        try await host.client.retryMeetingVoices(id: id)
        // The transcript is written again: the copy in the notes folder is of the old one.
        MeetingSettings.setExportStale(id, true, host.defaults)
        track(id)
    }

    func retryNotes(id: String) async throws {
        try await host.client.retryMeetingNotes(id: id)
        track(id)
    }

    func rename(id: String, title: String) async throws {
        _ = try await host.client.renameMeeting(id: id, title: title)
        // The copy in the notes folder carries the old title in its name and headings. Only a finished `track` copies a
        // meeting flagged stale, and a rename starts none, so a read that fails is tried again here and then said.
        MeetingSettings.setExportStale(id, true, host.defaults)
        // Not awaited: the window's refresh must not wait for the retries (#270).
        Task { await refreshCopy(id) }
    }

    private func refreshCopy(_ id: String) async {
        let client = host.client
        let info = await StaleCopyRefresh.run(read: { try? await client.meeting(id: id, withTexts: true) },
                                              sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
        if let info { export(info) } else { host.notify(L10nKey.noticeMeetingCopyStale.text) }
    }

    func settingsChanged() {
        applyCallMode()
        render()
    }

    func shutDown() {
        isShutDown = true
        // A recording in progress ends the way the Stop button ends it, then everything that watches goes quiet.
        if current != nil { stop() }
        watcher.stop()
        host.callActivity.setCallSeen(false)
        badge.hide()
        tick?.invalidate()
        tick = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    // MARK: settings

    private func openFolder() { NotesFolder.open(host.defaults) }

    private func chooseFolder() { NotesFolder.choose(host.defaults) }

    private func askName() {
        let alert = NSAlert()
        alert.messageText = L10nKey.menuMeetingYourName.text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = MeetingSettings.displayName(host.defaults, fallback: NSFullUserName())
        alert.accessoryView = field
        alert.addButton(withTitle: L10nKey.commonOk.text)
        alert.addButton(withTitle: L10nKey.commonCancel.text)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { MeetingSettings.setDisplayName(field.stringValue, host.defaults) }
    }

    private func installModel() {
        Task { @MainActor in
            do { try await host.client.installNotesModel() } catch { host.notify(MeetingErrorText.sentence(error, action: .installModel)) }
            render()
        }
    }
}
