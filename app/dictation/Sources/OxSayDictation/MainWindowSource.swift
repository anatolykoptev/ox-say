import AppKit
import AVFoundation
import DictationCore
import MainWindowUI
import UserNotifications

/// What the main window needs of the app around it. Closures, so the source never reaches into AppDelegate.
struct MainWindowHost {
    var client: StudioClient
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
    var startAtLogin: () -> Bool
    var setStartAtLogin: (Bool) -> Void
    var checkForUpdates: () -> Void
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
    /// Each click on a line is one request; a probe that comes back after another click, a stop or a close is dropped.
    private var playRequests = PlayRequestGuard()
    private var detailReads = DetailReads()
    /// Open (shown, hidden or covered) until the window is closed. A hidden window keeps its audio playing.
    private var windowOpen = false
    private var searchTimer: Task<Void, Never>?
    private var searchRequest: Task<Void, Never>?

    init(host: MainWindowHost) {
        self.host = host
        self.service = MeetingWindowService(client: host.client)
        self.model = MainWindowModel(data: Self.blank(host))
        model.actions = actions()
        audio.onChange = { [weak self] values in self?.model.data.playback = values }
        audio.onFailure = { [weak self] in self?.model.data.notice = L10nKey.playFailed.text }
    }

    // MARK: window lifecycle

    /// Every open: the data is read again, whatever it was when the window was last closed.
    func windowOpened() {
        windowOpen = true
        visible = true
        // A search that was running when the window closed was cancelled: run it again rather than show a spinner.
        if model.data.search.phase == .searching { searchEvent(.retry) }
        refresh()
    }

    func windowClosed() {
        windowOpen = false
        cancelSearchWork()
        stopPlayback()
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
        // A call's audio never plays while a recording runs, visible window or not.
        if host.meetings()?.recordingElapsed != nil { stopPlayback() }
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
            guard let self, NotesFolder.choose(self.host.defaults) else { return }
            self.reloadSettings()
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
                // The daemon status is read beside the list, not before it: a hung /status must not hold back the
                // list read, whose answer ("unreachable" included) is what the window shows. It is awaited at the
                // end of the pass, so passes never overlap it.
                let status = Task { @MainActor in await host.refreshStatus() }
                let (list, load) = await service.list()
                if let list { model.data.meetings = list }
                model.data.meetingsLoad = load
                await reloadSettingsAsync()
                await reloadPermissions()
                refreshSelectedDetail()
                await status.value
            } while gate.finish()
            schedulePolling()
        }
    }

    private func schedulePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard MeetingsPolling.needed(visible: visible, meetings: model.data.meetings, writer: model.data.meetingSettings.notesWriter) else { return }
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MeetingsPolling.interval * 1_000_000_000))
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
        model.data.voices = VoicesValues(voices: host.knownVoices(), russianVoice: d.string(forKey: "speakVoiceRU"),
                                         englishVoice: d.string(forKey: "speakVoiceEN"))
        model.data.about = AboutValues(version: AboutPanel.appVersion, engineRunning: host.daemonStatus() != nil,
                                       startAtLogin: host.startAtLogin())
    }

    private func reloadSettings() { Task { @MainActor in await reloadSettingsAsync() } }

    /// The settings from their stores; the daemon's retention wins over the app's copy.
    private func reloadSettingsAsync() async {
        let daemon = try? await host.client.meetingDaemonSettings()
        let notes = host.daemonStatus()?.notes
        model.data.meetingSettings = MeetingSettingsModel.load(
            defaults: host.defaults, daemonRetention: daemon?.retention, notesWriter: NotesWriterState.of(notes),
            fullName: NSFullUserName())
    }

    private func reloadPermissions() async {
        let center = await UNUserNotificationCenter.current().notificationSettings()
        let notifications: PermissionAuth = (center.authorizationStatus == .authorized || center.authorizationStatus == .provisional)
            ? .authorized : (center.authorizationStatus == .notDetermined ? .notDetermined : .denied)
        let mic: PermissionAuth
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .authorized
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
        model.data.permissions = PermissionModel.items(microphone: mic, accessibility: AXIsProcessTrusted(), notifications: notifications)
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

    /// The chosen meeting is read again when the list says it moved on (processing finished, the notes arrived).
    private func refreshSelectedDetail() {
        guard let id = model.selectedMeeting, let row = model.data.meetings.first(where: { $0.id == id }) else { return }
        guard let shown = model.data.details[id]?.info, shown.status != row.status || shown.title != row.title else { return }
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
                model.data.notice = L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .retry))
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
            case .autoStart: host.meetings()?.settingsChanged()
            case .retention, .mode, .name: break
            }
            if case .enabled(let on) = change, on, host.meetings() is UnsupportedMeetings {
                model.data.notice = L10nKey.menuMeetingNeedsNewerMacOS.text
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
