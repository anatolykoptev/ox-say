import AppKit
import AVFoundation
import Combine
import DictationCore
import MainWindowUI
import UserNotifications

/// What the main window needs of the app around it. Closures, so the source never reaches into AppDelegate.
struct MainWindowHost {
    var client: StudioClient
    var speech: SpeechClient
    var defaults: UserDefaults
    /// The running meeting feature, nil while meetings are off.
    var meetings: () -> MeetingFeature?
    /// Meetings were switched on or off in the window: create or tear down the feature, the menu item and the icon.
    var meetingsEnabledChanged: () -> Void
    var daemonStatus: () -> DaemonStatus?
    /// Reads /status now: the window's rows must not show what the last menu open saw.
    var refreshStatus: () async -> Void
    var dictationKeyTitle: () -> String?
    var recentDictations: () -> [String]
    var knownVoices: () -> [String]
    var setHotkeyMode: (HotkeyMode) -> Void
    /// The sound pick was saved: the menu's check marks follow it.
    var soundChanged: () -> Void
    var pickVoice: (VoiceSlot, String?) -> Void
    /// The voice library changed (a voice was deleted or renamed, or the list was read): the menu's voice list and
    /// its read-aloud checkmarks follow.
    var voicesChanged: ([String]) -> Void
    var startAtLogin: () -> Bool
    var setStartAtLogin: (Bool) -> Void
    var checkForUpdates: () -> Void
    /// The studio voice install (its own confirmation alert included): the Voices page's «Скачать студийный голос».
    var installStudioVoice: () -> Void
    /// The describe-a-voice driver, owned by the Studio controller: its `running` is what the version handshake reads.
    var designer: () -> VoiceDesigner
    /// A dictation is recording and holding the microphone, read live: a voice take must never start beside it.
    var dictationRecording: () -> Bool
    /// Work the window was doing has ended (a voice take closed, saved or was thrown away): a version handshake
    /// held back for it runs again.
    var workEnded: () -> Void
    /// True once, on the first ever launch: Озвучка opens with its sample text instead of an empty editor.
    var consumeFirstRun: () -> Bool
    /// Why a new speak request must wait (an update is installing), else nil.
    var speechRefusal: () -> String?
    /// The one OxSay window, for the save panel to attach to.
    var mainWindow: () -> NSWindow?
    /// Stops the app's own speech player (speak-selection and voiceover playback): a clip never overlaps it.
    var stopSpeechPlayer: () -> Void
    /// The voiceover the app follows, shared with the Studio menu: a studio project started on Озвучка is followed by it.
    var voiceover: () -> VoiceoverService
    /// The save panel for a transcript (a sheet on the main window); the answer says whether the file was written.
    var saveFile: (TranscriptFile, @escaping (Bool) -> Void) -> Void
}

/// Fills the main window with what the app really has and carries out what the window asks. The window holds no timer:
/// this class polls while the window is open and a meeting is still being processed, and ticks the clock of a running
/// recording once a second; both stop when the window closes. Decisions are DictationCore's.
@MainActor
final class MainWindowSource {
    let model: MainWindowModel
    private let host: MainWindowHost
    private let service: MeetingWindowService
    private var visible = false
    private var pollTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var gate = RefreshGate()
    private let audio = MeetingAudioPlayer()
    private var voiceSource: VoiceSource!
    private var speakSource: SpeakSource!
    private var transcribeSource: TranscribeSource!
    /// Each click on a line is one request; a probe that comes back after another click, a stop or a close is dropped.
    private var playRequests = PlayRequestGuard()
    private var detailReads = DetailReads()
    /// Reads again when the app becomes active (a permission granted in System Settings); alive only while the window is open.
    private var activeObserver: NSObjectProtocol?
    /// When the permissions were last read (monotonic clock), to tell an activation that follows a read from a real return.
    private var lastPermissionRead: TimeInterval?
    /// The last notification answer; stands until the next read lands (nil until the first one: the row stays out meanwhile).
    private var notificationAuth: PermissionAuth?
    /// The notification read in flight, if any; cleared when it lands.
    private var notificationRead: Task<Void, Never>?
    /// Open (shown, hidden or covered) until the window is closed. A hidden window keeps its audio playing.
    private var windowOpen = false
    private var searchTimer: Task<Void, Never>?
    private var searchRequest: Task<Void, Never>?
    /// Saves the route on every change (a quit with the window open never calls windowClosed).
    private var routeSaver: AnyCancellable?
    /// The section the window showed before the last change, for the arrival rule of the Озвучка recheck.
    private var lastSection: MainSection = .speak
    /// A meeting restored from the last run is checked against the first non-empty list that loads: an empty
    /// one says nothing yet (the daemon may still be coming up), so the check stays armed for the next list.
    private var restoredMeetingUnchecked = false

    init(host: MainWindowHost) {
        self.host = host
        self.service = MeetingWindowService(client: host.client)
        self.model = MainWindowModel(data: Self.blank(host))
        model.advanced = AdvancedMode.isOn(host.defaults)
        let restored = WindowRestoration.load(host.defaults, advanced: model.advanced)
        model.section = restored.section
        lastSection = restored.section
        model.selectedMeeting = restored.meetingID
        restoredMeetingUnchecked = restored.meetingID != nil
        voiceSource = VoiceSource(model: model, client: host.client, speech: host.speech, defaults: host.defaults,
                                  recordingRunning: { host.meetings()?.recordingElapsed != nil },
                                  dictationRecording: { host.dictationRecording() },
                                  windowGone: { [weak self] in self?.windowOpen == false },
                                  workEnded: { host.workEnded() },
                                  designer: host.designer(),
                                  changed: { [weak self] voices in
                                      host.voicesChanged(voices)
                                      self?.speakSource.voicesChanged()
                                  })
        speakSource = SpeakSource(model: model, host: host)
        transcribeSource = TranscribeSource(model: model, host: host)
        if let id = restored.speakID { speakSource.openProject(id) }
        speakSource.stopOtherAudio = { [weak self] in
            self?.voiceSource.stopPreview()
            self?.stopPlayback()
            host.stopSpeechPlayer()
        }
        let defaults = host.defaults
        model.advancedChanged = { [weak model] on in
            AdvancedMode.set(on, in: defaults)
            guard let model else { return }
            model.section = AdvancedMode.section(after: on, current: model.section)
        }
        let openVoiceover = model.$data.map(\.speak.routeProjectID).removeDuplicates()
        routeSaver = Publishers.CombineLatest3(model.$section, model.$selectedMeeting, openVoiceover).dropFirst().sink { [weak self] section, meeting, speak in
            WindowRestoration.save(MainRoute(section: section, meetingID: meeting, speakID: speak), to: defaults)
            // Arriving on Озвучка with the daemon down reads at once (the backoff grew on passes made elsewhere) and starts
            // its recheck without waiting for another refresh pass.
            Task { @MainActor in
                guard let self else { return }
                let arrived = SpeakRecheck.refreshOnArrival(to: self.model.section, from: self.lastSection, reach: self.speakSource.reach)
                self.lastSection = self.model.section
                self.schedulePolling()
                if arrived { self.refresh() }
            }
        }
        model.actions = actions()
        audio.onChange = { [weak self] values in self?.model.data.playback = values }
        audio.onFailure = { [weak self] in self?.model.data.notice = L10nKey.playFailed.text }
    }

    // MARK: window lifecycle

    /// Every open: the data is read again, whatever it was when the window was last closed.
    func windowOpened() {
        windowOpen = true
        visible = true
        observeActivation()
        // A search that was running when the window closed was cancelled: run it again rather than show a spinner.
        if model.data.search.phase == .searching { searchEvent(.retry) }
        refresh()
    }

    /// The window comes back from System Settings (or any app) with the old permissions on screen: the app becoming
    /// active reads everything again. `refresh()` is gated, so this never runs reads beside another pass.
    private func observeActivation() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.voiceSource.microphoneMayHaveChanged()
                guard ActivationRefresh.shouldRefresh(windowOpen: self.windowOpen, visible: self.visible,
                                                      now: ProcessInfo.processInfo.systemUptime,
                                                      lastPermissionRead: self.lastPermissionRead) else { return }
                self.refresh()
            }
        }
    }

    /// The menu's Create a Voice: the sheet over the Voices page (the caller has already shown that section).
    func openVoiceDesign() {
        // The studio voice cannot run (the status changed since the menu drew the row): the page the caller has shown
        // has the disabled button and its reason; the same reason is said on top of it.
        guard model.data.voices.designAvailability == .available else {
            if case .unavailable(let reason) = model.data.voices.designAvailability { model.data.notice = reason }
            else { model.data.notice = L10nKey.voicesDescribeInstallable.text }
            return
        }
        voiceSource.design(.open)
    }

    /// The person is recording their own voice (a take in progress, kept or being sent): the version handshake waits.
    var recordingVoice: Bool { voiceSource.recordingVoice }

    /// The app's own player starts (speak-selection, voiceover): a clip on Озвучка stops first.
    func stopSpeakClip() { speakSource.stopClip() }

    /// A speak request is on its way or a clip sounds: the version handshake waits for it.
    var speakBusy: Bool { speakSource.busy }

    /// A file is being uploaded or transcribed: the version handshake waits for it.
    var transcribing: Bool { transcribeSource.transcribing }

    /// Points the window at a section (and a meeting). A route without a meeting leaves the open one alone.
    func apply(_ route: MainRoute) {
        let route = route.resolved(visible: MainWindowSpec.sections(advanced: model.advanced))
        model.section = route.section
        if let id = route.meetingID { model.selectedMeeting = id }
        if let id = route.speakID { speakSource.showProject(id) }
    }

    func windowClosed() {
        windowOpen = false
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        cancelSearchWork()
        stopPlayback()
        speakSource.windowClosed()
        voiceSource.stopPreview()
        voiceSource.quietDesign()
        voiceSource.quietFile()
        voiceSource.quietRecording()
        stopClocks()
    }

    /// Minimised, covered or the app hidden: nothing is polled and no clock ticks; shown again, it reads once. The audio
    /// is not touched: someone listening to a meeting while working in another app keeps hearing it.
    func visibilityChanged(_ nowVisible: Bool) {
        guard nowVisible != visible else { return }
        if nowVisible {
            visible = true
            refresh()
        } else {
            stopClocks()
        }
    }

    private func stopClocks() {
        visible = false
        pollTask?.cancel()
        pollTask = nil
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// The meeting feature started or stopped a recording (or was switched off).
    func recordingChanged() {
        // A call's audio never plays while a recording runs, visible window or not — nor does a voice's sample.
        if host.meetings()?.recordingElapsed != nil { stopPlayback(); voiceSource.stopPreview(); voiceSource.quietDesign(); voiceSource.meetingStarted() }
        if host.meetings()?.recordingElapsed != nil { speakSource.recordingStarted() }
        guard visible else { return }
        syncRecording()
        refresh()
    }

    /// A sentence the app said elsewhere (the status line) that the window must not miss while it is open.
    func noticeFromApp(_ message: String) {
        guard visible else { return }
        model.data.notice = message
    }

    // MARK: reading

    private func actions() -> MainWindowActions {
        var a = MainWindowActions()
        a.refresh = { [weak self] in self?.refresh() }
        a.selectMeeting = { [weak self] id in self?.selectMeeting(id) }
        a.startRecording = { [weak self] in self?.host.meetings()?.startRecording() }
        a.stopRecording = { [weak self] in self?.host.meetings()?.stop() }
        a.deleteMeeting = { [weak self] id in self?.delete(id) }
        a.renameMeeting = { [weak self] id, title in self?.rename(id, title) }
        a.copyNotes = { [weak self] id in self?.copyNotes(id) }
        a.openMeetingFolder = { [weak self] id in self?.openFolder(id) }
        a.retryNotes = { [weak self] id in self?.retryNotes(id) }
        a.retryVoices = { [weak self] id in self?.retryVoices(id) }
        a.saveSpeakers = { [weak self] id, edits in self?.saveSpeakers(id, edits) }
        a.changeMeetingSetting = { [weak self] change in self?.apply(change) }
        a.openPermissionPane = { pane in
            if let url = URL(string: pane.settingsURL) { NSWorkspace.shared.open(url) }
        }
        a.chooseNotesFolder = { [weak self] in
            guard let self, let url = NotesFolder.choose(self.host.defaults) else { return }
            self.reloadSettings(pickedFolder: url)
        }
        a.openNotesFolder = { [weak self] in
            guard let self else { return }
            NotesFolder.open(self.host.defaults)
        }
        a.downloadNotesWriter = { [weak self] in self?.downloadNotesWriter() }
        a.checkForUpdates = { [weak self] in self?.host.checkForUpdates() }
        a.setSound = { [weak self] mode in
            guard let self else { return }
            DictationSettings.setSound(mode, self.host.defaults)
            self.host.soundChanged()
        }
        a.setHotkeyMode = { [weak self] mode in self?.host.setHotkeyMode(mode) }
        a.pickVoice = { [weak self] slot, voice in self?.host.pickVoice(slot, voice) }
        a.reloadVoices = { [weak self] in self?.voiceSource.reload() }
        a.previewVoice = { [weak self] id in self?.speakSource.stopClip(); self?.voiceSource.preview(id) }
        a.stopPreview = { [weak self] in self?.voiceSource.stopPreview() }
        a.renameVoice = { [weak self] id, label in self?.voiceSource.rename(id, label) }
        a.deleteVoice = { [weak self] id in self?.voiceSource.delete(id) }
        a.voiceDesign = { [weak self] step in self?.voiceSource.design(step) }
        a.voiceFile = { [weak self] step in self?.voiceSource.file(step) }
        a.voiceRecord = { [weak self] step in self?.voiceSource.recording(step) }
        a.installStudioVoice = { [weak self] in self?.host.installStudioVoice() }
        a.setStartAtLogin = { [weak self] on in
            guard let self else { return }
            self.host.setStartAtLogin(on)
            self.model.data.about.startAtLogin = self.host.startAtLogin()
        }
        a.dismissNotice = { [weak self] in self?.model.data.notice = nil }
        a.searchTyped = { [weak self] text in self?.searchEvent(.typed(text)) }
        a.retrySearch = { [weak self] in self?.searchEvent(.retry) }
        a.playTurn = { [weak self] id, turn in self?.playTurn(id, turn) }
        a.togglePlayback = { [weak self] in self?.audio.toggle() }
        a.seekPlayback = { [weak self] seconds in self?.audio.seek(to: seconds) }
        a.stopPlayback = { [weak self] in self?.stopPlayback() }
        a.speakGenerate = { [weak self] in self?.speakSource.generate() }
        a.speakVariant = { [weak self] in self?.speakSource.generate(variant: true) }
        a.speakStop = { [weak self] in self?.speakSource.stop() }
        a.speakRowAction = { [weak self] action in self?.speakSource.runRowAction(action) }
        a.speakPlayPause = { [weak self] in self?.speakSource.playPause() }
        a.speakSave = { [weak self] in self?.speakSource.save() }
        a.speakNewText = { [weak self] in self?.speakSource.newText() }
        a.speakSelect = { [weak self] id in self?.speakSource.select(id) }
        a.speakTextChanged = { [weak self] text in self?.speakSource.textChanged(text) }
        a.speakVoiceChanged = { _ in }
        a.speakQualityChanged = { [weak self] quality in self?.speakSource.qualityChanged(quality) }
        a.speakNewReel = { [weak self] in self?.speakSource.newReel() }
        a.speakOpenDocument = { [weak self] url in self?.speakSource.openDocument(url) }
        a.speakKeepFirstPart = { [weak self] in self?.speakSource.keepFirstPart() }
        a.phrasePlay = { [weak self] n in self?.speakSource.playPhrase(n) }
        a.phraseVariant = { [weak self] n in self?.speakSource.anotherVariant(n) }
        a.phrasePickOther = { [weak self] n in self?.speakSource.pickOtherVariant(n) }
        a.phraseMood = { [weak self] n, mood in self?.speakSource.setMood(n, mood) }
        a.phraseEditText = { [weak self] n, text in self?.speakSource.editPhraseText(n, text) }
        a.speakLoudness = { [weak self] target in self?.speakSource.setLoudness(target) }
        a.speakPace = { [weak self] value in self?.speakSource.setPace(value) }
        a.speakPause = { [weak self] value in self?.speakSource.setPause(value) }
        a.speakPanelChanged = { [weak self] settings in self?.speakSource.panelChanged(settings) }
        a.transcribePick = { [weak self] url in self?.transcribeSource.pick(url) }
        a.transcribeReload = { [weak self] in self?.transcribeSource.reload() }
        a.transcribeSelect = { [weak self] id in self?.transcribeSource.select(id) }
        a.transcribeCopy = { [weak self] id in self?.transcribeSource.copy(id) }
        a.transcribeSave = { [weak self] id, format in self?.transcribeSource.save(id, format) }
        a.transcribeDelete = { [weak self] id in self?.transcribeSource.delete(id) }
        return a
    }

    /// Reads everything the window shows. The list and the settings come from the daemon, so they are awaited; a failed
    /// read keeps what is on screen and says why. A request made while a read runs makes one more pass.
    func refresh() {
        guard gate.request() else { return }
        Task { @MainActor in
            repeat {
                syncRecording()
                loadSimpleSections()
                voiceSource.reload()
                transcribeSource.reload()
                // The permission rows are read before any daemon call (microphone and Accessibility at once). The
                // notification answer merges when it lands; the pass never waits for it, so a stuck read holds
                // nothing back, least of all the gate.
                readPermissions()
                // The daemon status is read beside the list, not before it: a hung /status must not hold back the
                // list read, whose answer ("unreachable" included) is what the window shows. It is awaited at the
                // end of the pass, so passes never overlap it.
                let status = Task { @MainActor in await host.refreshStatus() }
                let (list, load) = await service.list()
                if let list {
                    model.data.meetings = list
                    if restoredMeetingUnchecked {
                        restoredMeetingUnchecked = list.isEmpty
                        model.selectedMeeting = MainRoute(section: model.section, meetingID: model.selectedMeeting)
                            .pruned(knownMeetingIDs: list.map(\.id)).meetingID
                    }
                }
                model.data.meetingsLoad = load
                await reloadSettingsAsync()
                refreshSelectedDetail()
                await status.value
                updateDesignAvailability()
                speakSource.statusRead()
            } while gate.finish()
            schedulePolling()
        }
    }

    private func schedulePolling() {
        pollTask?.cancel()
        pollTask = nil
        // The next read is due when a meeting is still being processed, or when Озвучка is in view and the daemon does not
        // answer (it backs off, so a daemon that never comes up is asked rarely): whichever is sooner.
        let meetings = MeetingsPolling.needed(visible: visible, meetings: model.data.meetings, writer: model.data.meetingSettings.notesWriter)
        let due = [meetings ? MeetingsPolling.interval : nil, speakSource.recheckDelay(visible: visible, section: model.section)].compactMap { $0 }
        guard let delay = due.min() else { return }
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The recording bar: elapsed time from the meeting feature itself, ticking once a second while one runs.
    private func syncRecording() {
        model.data.recordingElapsed = host.meetings()?.recordingElapsed
        guard visible, model.data.recordingElapsed != nil else {
            clockTimer?.invalidate()
            clockTimer = nil
            return
        }
        // Already ticking: a refresh does not rebuild the clock.
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.data.recordingElapsed = self.host.meetings()?.recordingElapsed
                if self.model.data.recordingElapsed == nil { self.syncRecording() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func loadSimpleSections() {
        let d = host.defaults
        model.data.dictation = DictationValues(keyTitle: host.dictationKeyTitle(), mode: DictationSettings.mode(d),
                                               sound: DictationSettings.sound(d), recent: host.recentDictations())
        // The library itself (entries, playing) belongs to VoiceSource; only the ids are borrowed from the menu's list
        // until its first read lands.
        model.data.voices.russianVoice = d.string(forKey: DictationSettings.speakVoiceRUKey)
        model.data.voices.englishVoice = d.string(forKey: DictationSettings.speakVoiceENKey)
        if model.data.voices.entries.isEmpty, model.data.voices.load != .loaded { model.data.voices.voices = host.knownVoices() }
        model.data.about = AboutValues(version: AboutPanel.appVersion, engineRunning: host.daemonStatus() != nil,
                                       startAtLogin: host.startAtLogin())
        updateDesignAvailability()
    }

    /// Whether «Описать словами» can be used, from the daemon's last /status.
    private func updateDesignAvailability() {
        let availability = DesignAvailability.of(host.daemonStatus())
        if model.data.voices.designAvailability != availability { model.data.voices.designAvailability = availability }
    }

    private func reloadSettings(pickedFolder url: URL) { Task { @MainActor in await reloadSettingsAsync(pickedFolder: url) } }

    /// The settings from their stores; the daemon's retention wins over the app's copy. A picked
    /// folder is stored before the daemon round-trip (up to 10 s), so new notes go to it at once, and
    /// read back through the model's one step after the reply, so the iCloud answer is the new folder's own.
    private func reloadSettingsAsync(pickedFolder: URL? = nil) async {
        if let pickedFolder { MeetingSettings.setFolder(pickedFolder, host.defaults) }
        let daemon = try? await host.client.meetingDaemonSettings()
        let notes = host.daemonStatus()?.notes
        model.data.meetingSettings = pickedFolder.map {
            MeetingSettingsModel.folderPicked($0, defaults: host.defaults, daemonRetention: daemon?.retention,
                                              notesWriter: NotesWriterState.of(notes), fullName: NSFullUserName())
        } ?? MeetingSettingsModel.load(
            defaults: host.defaults, daemonRetention: daemon?.retention, notesWriter: NotesWriterState.of(notes),
            fullName: NSFullUserName())
    }

    /// Stamps and sets the microphone and Accessibility rows at once, and starts the notification read unless one is
    /// already running. The pass does not wait for it; the last answer stands until it lands. One read in flight:
    /// a stuck read blocks nothing, two reads cannot overlap, and a newer answer is never overwritten by an older one.
    private func readPermissions() {
        // Stamped before the first read. A toggle that lands after the last read is not seen by this read; the gap is
        // about one second after it, and the next poll or activation heals that.
        lastPermissionRead = ProcessInfo.processInfo.systemUptime
        applyPermissions()
        guard notificationRead == nil else { return }
        notificationRead = Task { @MainActor in
            let center = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuth = (center.authorizationStatus == .authorized || center.authorizationStatus == .provisional)
                ? .authorized : (center.authorizationStatus == .notDetermined ? .notDetermined : .denied)
            notificationRead = nil
            applyPermissions()
        }
    }

    /// The rows from the two synchronous reads and the last known notification answer.
    private func applyPermissions() {
        let mic: PermissionAuth
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .authorized
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
        model.data.permissions = PermissionModel.items(microphone: mic, accessibility: AXIsProcessTrusted(), notifications: notificationAuth)
    }

    // MARK: search

    /// The search runs as DictationCore decides: the state is the core's, and this carries out its effects.
    private func searchEvent(_ event: MeetingSearchEvent) {
        var state = model.data.search
        let effects = MeetingSearch.reduce(&state, event)
        model.data.search = state
        for effect in effects {
            switch effect {
            case .cancelInFlight:
                cancelSearchWork()
            case .startTimer(let generation, let delay):
                searchTimer?.cancel()
                searchTimer = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.searchEvent(.timerFired(generation: generation))
                }
            case .run(let generation, let query):
                searchRequest?.cancel()
                let client = host.client
                searchRequest = Task { @MainActor [weak self] in
                    let answer = await client.searchMeetings(query: query)
                    // A cancelled request is a stale one: its answer, whatever it is, is not read.
                    guard !Task.isCancelled else { return }
                    self?.searchEvent(.answered(generation: generation, answer))
                }
            }
        }
    }

    /// The timer and the request that run now stop; nothing of a search outlives a closed window.
    private func cancelSearchWork() {
        searchTimer?.cancel()
        searchRequest?.cancel()
        searchTimer = nil
        searchRequest = nil
    }

    // MARK: playback

    /// Stops the audio and forgets any click whose probe is still on its way.
    private func stopPlayback() {
        playRequests.invalidate()
        audio.stop()
    }

    private func selectMeeting(_ id: String) {
        if audio.activeMeeting != id { stopPlayback() }
        loadDetail(id)
    }

    /// A click on a transcript line. The gate is read here, from the live recording state, not from what the page
    /// drew: a recording that began a moment ago still refuses.
    private func playTurn(_ id: String, _ turn: TranscriptTurn) {
        guard let info = model.data.details[id]?.info else { return }
        let gate = PlaybackGate.decide(audioDeleted: info.audioDeleted, recordingRunning: host.meetings()?.recordingElapsed != nil,
                                       status: info.status)
        switch PlaybackPlan.start(turn: turn, gate: gate) {
        case .refused(.recording):
            stopPlayback()
            model.data.notice = L10nKey.playBlockedRecording.text
        case .refused(.unavailable):
            break
        case .play(let start):
            let request = playRequests.begin()
            Task { @MainActor in
                let probe = await host.client.probeMeetingAudio(id: id)
                guard playRequests.isCurrent(request, windowOpen: windowOpen) else { return }
                switch probe {
                case .available:
                    // The recording may have begun while the probe was on its way.
                    guard host.meetings()?.recordingElapsed == nil else {
                        model.data.notice = L10nKey.playBlockedRecording.text
                        return
                    }
                    speakSource.stopClip()
                    audio.play(url: host.client.meetingAudioURL(id: id), meetingID: id, from: start)
                case .removed:
                    // Retention took it: the line says so once (the header notice) and offers no play any more.
                    model.data.details[id]?.info.audioDeleted = true
                    if let i = model.data.meetings.firstIndex(where: { $0.id == id }) { model.data.meetings[i].audioDeleted = true }
                case .stillRecording:
                    model.data.notice = L10nKey.playBlockedRecording.text
                case .failed(let sentence):
                    model.data.notice = sentence
                }
            }
        }
    }

    // MARK: meetings

    /// One read per meeting at a time (`DetailReads`): a polling pass that finds one running asks for one more after it.
    private func loadDetail(_ id: String) {
        guard let token = detailReads.request(id) else { return }
        model.data.detailLoading.insert(id)
        model.data.detailError[id] = nil
        Task { @MainActor in
            let result = await service.detail(id: id)
            let outcome = detailReads.finish(id, token: token)
            guard outcome.apply else { return } // given up (the meeting was deleted): nothing of it lands
            switch result {
            case .success(let detail): model.data.details[id] = detail
            case .failure(let failure): model.data.detailError[id] = failure.sentence
            }
            if outcome.rerun { loadDetail(id) } else { model.data.detailLoading.remove(id) }
        }
    }

    /// The chosen meeting is read when it was never read (a restored selection fires no `onChange`) or when the
    /// list says it moved on (processing finished, the notes arrived).
    private func refreshSelectedDetail() {
        guard let id = model.selectedMeeting, let row = model.data.meetings.first(where: { $0.id == id }) else { return }
        guard DetailRead.needed(row: row, shown: model.data.details[id]?.info, failed: model.data.detailError[id] != nil, loading: model.data.detailLoading.contains(id)) else { return }
        loadDetail(id)
    }

    private func delete(_ id: String) {
        Task { @MainActor in
            switch await service.delete(id: id) {
            case .done, .alreadyGone:
                detailReads.cancel(id)
                model.data.detailLoading.remove(id)
                model.data.details[id] = nil
                if model.selectedMeeting == id { model.selectedMeeting = nil }
                model.data.meetings.removeAll { $0.id == id }
                refresh()
            case .failed(let sentence):
                model.data.notice = sentence
            }
        }
    }

    private func rename(_ id: String, _ title: String) {
        Task { @MainActor in
            do {
                guard let meetings = host.meetings() else { throw MeetingFeatureError.switchedOff }
                try await meetings.rename(id: id, title: title)
                loadDetail(id)
                refresh()
            } catch {
                model.data.notice = MeetingErrorText.sentence(error, action: .rename)
            }
        }
    }

    private func saveSpeakers(_ id: String, _ edits: SpeakerEdits) {
        Task { @MainActor in
            do {
                guard let meetings = host.meetings() else { throw MeetingFeatureError.switchedOff }
                let state = try await meetings.saveSpeakers(id: id, edits: edits)
                if var detail = model.data.details[id] { detail.speakers = state; model.data.details[id] = detail }
                loadDetail(id)
                refresh()
            } catch {
                model.data.notice = L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .speakers))
            }
        }
    }

    private func retryVoices(_ id: String) {
        Task { @MainActor in
            do {
                guard let meetings = host.meetings() else { throw MeetingFeatureError.switchedOff }
                try await meetings.requestVoicesAgain(id: id)
                refresh()
            } catch {
                model.data.notice = L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .retryVoices))
            }
        }
    }

    private func retryNotes(_ id: String) {
        Task { @MainActor in
            do {
                guard let meetings = host.meetings() else { throw MeetingFeatureError.switchedOff }
                try await meetings.retryNotes(id: id)
                refresh()
            } catch {
                model.data.notice = MeetingErrorText.sentence(error, action: .retry)
            }
        }
    }

    /// The one clipboard write of the window, and only on the user's click: the notes' Markdown as the daemon wrote it.
    private func copyNotes(_ id: String) {
        guard let markdown = model.data.details[id]?.info.notesMD else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        model.data.notice = L10nKey.meetingCopied.text
    }

    private func openFolder(_ id: String) {
        let fm = FileManager.default
        let target = MeetingFolderTarget.resolve(exportPath: MeetingSettings.exportPath(id, host.defaults),
                                                 notesFolder: MeetingSettings.folder(host.defaults),
                                                 exists: { fm.fileExists(atPath: $0) })
        switch target {
        case .copy(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .notesFolder(let url): NSWorkspace.shared.open(url)
        case .nowhere: model.data.notice = L10nKey.meetingFolderNone.text
        }
    }

    private func downloadNotesWriter() {
        Task { @MainActor in
            do { try await host.client.installNotesModel() } catch {
                model.data.notice = MeetingErrorText.sentence(error, action: .settings)
            }
            // The writer now reads "downloading", which keeps the poll going until it is done.
            refresh()
        }
    }

    // MARK: settings

    /// Saves one edit where it lives. A save that did not go through is said, and the page shows the stored value again.
    private func apply(_ change: MeetingSettingsModel.Change) {
        // Switching meetings off ends the audio at once, whatever the save then says.
        if case .enabled(false) = change { stopPlayback() }
        Task { @MainActor in
            let applier = MeetingSettingsApplier(defaults: host.defaults, client: host.client)
            if let failure = await applier.apply(change) {
                model.data.notice = failure
                await reloadSettingsAsync()
                return
            }
            switch change {
            case .enabled: host.meetingsEnabledChanged()
            case .callMode: host.meetings()?.settingsChanged()
            case .retention, .mode, .name: break
            }
            if case .retention = change { model.data.meetingSettings.retentionVerified = true }
            // A name is typed letter by letter: only a change that alters other parts of the page reads it all again.
            if change.needsRefresh { refresh() }
        }
    }

    // MARK: first values

    /// What the window shows before the first read: nothing real yet, so nothing is made up.
    private static func blank(_ host: MainWindowHost) -> MainWindowData {
        MainWindowData(
            meetings: [], meetingsLoad: .loading, details: [:],
            meetingSettings: MeetingSettingsModel.load(defaults: host.defaults, daemonRetention: nil, notesWriter: .unavailable(.meetingErrDaemonDown),
                                                       fullName: NSFullUserName()),
            permissions: [],
            dictation: DictationValues(keyTitle: nil, mode: DictationSettings.mode(host.defaults), sound: DictationSettings.sound(host.defaults), recent: []),
            voices: VoicesValues(voices: [], russianVoice: nil, englishVoice: nil),
            about: AboutValues(version: AboutPanel.appVersion, engineRunning: false, startAtLogin: false))
    }
}
