import Foundation
import XCTest
@testable import DictationCore

/// The shim compiles DictationCore only, so the AppKit controller and recorder are not testable as code. What they
/// must DO is decided in DictationCore (RecordingMonitor, MeetingPolicy, Reconcile, StatusIconStyle, Reacquire, ...,
/// all tested behaviourally); these tests read the app sources as text, WITHOUT their comments, and pin that the
/// decisions are called from the place that matters, with the exact expression. They prove the call is there, not that
/// it behaves: the live run does that.
final class MeetingWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Self.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    /// Source without comments: a pinned call that is commented out must not pass. Block comments, and `//` to the end
    /// of the line when it starts a token (a `//` inside "https://…" does not).
    static func stripComments(_ text: String) -> String {
        let blocks = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return blocks.replacingOccurrences(of: #"(?m)(^|[ \t])//.*$"#, with: "$1", options: .regularExpression)
    }

    func testStripCommentsRemovesCommentedOutCalls() {
        let text = "a()\n    // meetings?.stopForQuit()\n    /* b() */ c(\"https://x\") // d()\n"
        let stripped = Self.stripComments(text)
        XCTAssertFalse(stripped.contains("stopForQuit"))
        XCTAssertFalse(stripped.contains("b()"))
        XCTAssertFalse(stripped.contains("d()"))
        XCTAssertTrue(stripped.contains("a()"))
        XCTAssertTrue(stripped.contains("https://x"))
    }

    /// The text of `func name` up to the next function at the same indentation (or the end).
    private func body(_ text: String, of signature: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    private func startTapCaptures(_ recorder: String) -> Bool {
        guard let body = body(recorder, of: "private func startTap() {") else { return false }
        return body.contains("let token = tapRecovery.token") && body.contains("self?.tapStarted(outcome, token: token)")
    }

    private func controller() throws -> String { try source("OxSayDictation/MeetingController.swift") }
    private func app() throws -> String { try source("OxSayDictation/AppDelegate.swift") }

    // MARK: AppDelegate

    /// Mutation: AppDelegate.appWork(), replace `meetings?.isRecording ?? false` with `false` -> RED.
    func testAppWorkReportsTheLiveRecording() throws {
        let work = try XCTUnwrap(body(try app(), of: "private func appWork() -> VersionHandshake.AppWork {"))
        XCTAssertTrue(work.contains("recordingMeeting: meetings?.isRecording ?? false"), work)
    }

    /// An update install relaunches the app and must not start under a recording: the exact guard, before the install.
    /// Mutation: AppDelegate.installUpdate, `guard meetings?.isRecording != true else {` -> `guard true else {`, or
    /// `... != true || true else {` -> RED.
    func testAnInstallNeverStartsUnderARecording() throws {
        let install = try XCTUnwrap(body(try app(), of: "private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {"))
        let guardAt = try XCTUnwrap(install.range(of: "guard meetings?.isRecording != true else {"))
        let installingAt = try XCTUnwrap(install.range(of: "updateInstalling = true"))
        XCTAssertLessThan(guardAt.lowerBound, installingAt.lowerBound, "the guard must come before the install begins")
        let after = install[guardAt.upperBound...].prefix(160)
        XCTAssertTrue(after.contains("return"), "the guard leaves the function")
    }

    /// Quit closes a recording and hands it to the daemon: the call, uncommented, in applicationWillTerminate.
    /// Mutation: AppDelegate.applicationWillTerminate, delete or comment out `meetings?.stopForQuit()` -> RED.
    func testQuitStopsARecording() throws {
        let quit = try XCTUnwrap(body(try app(), of: "func applicationWillTerminate(_ notification: Notification) {"))
        XCTAssertTrue(quit.contains("\n        meetings?.stopForQuit()\n"))
    }

    /// The icon's symbol and tint come from ONE decision over both states; nothing else sets the tint.
    /// Mutation: AppDelegate.applyStatusIcon, delete `dictationRecording: controller.state == .recording` -> RED;
    /// or a second `contentTintColor =` elsewhere -> RED.
    func testTheStatusIconIsDecidedFromBothStatesInOnePlace() throws {
        let text = try app()
        let icon = try XCTUnwrap(body(text, of: "private func applyStatusIcon() {"))
        XCTAssertTrue(icon.contains("StatusIconStyle.style(meetingRecording: meetings?.isRecording == true,"))
        XCTAssertTrue(icon.contains("dictationRecording: controller.state == .recording"))
        XCTAssertTrue(icon.contains("statusItem.button?.contentTintColor = style.red ? .systemRed : nil"))
        XCTAssertEqual(text.components(separatedBy: "contentTintColor =").count - 1, 1, "only applyStatusIcon sets the tint")
    }

    /// The host tells the controller whether an update installs.
    /// Mutation: AppDelegate.setUpMeetings, `updateInstalling: { false }` -> RED.
    func testTheHostReportsTheInstall() throws {
        let text = try app()
        XCTAssertTrue(text.contains("updateInstalling: { [unowned self] in self.updateInstalling }"))
    }

    // MARK: recorder and tap

    /// Every stamp is the buffer's CAPTURE time through HostClock, one t0 for both writers.
    /// Mutation: MeetingRecorder, stamp the mic chunk with `HostClock.nanos(fromHostTicks: AudioGetCurrentHostTime())`
    /// instead of `ticks` -> RED.
    func testTheRecorderStampsCaptureTimeFromOneClock() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        let tap = try source("OxSayDictation/SystemAudioTap.swift")
        XCTAssertFalse(recorder.contains("AudioConvertHostTimeToNanos"))
        XCTAssertFalse(tap.contains("AudioConvertHostTimeToNanos"))
        XCTAssertTrue(recorder.contains("when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime()"))
        XCTAssertTrue(recorder.contains("self.me?.append(samples, atNanos: HostClock.nanos(fromHostTicks: ticks))"))
        XCTAssertTrue(tap.contains("time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : AudioGetCurrentHostTime()"))
        XCTAssertTrue(tap.contains("HostClock.nanos(fromHostTicks: ticks)"))
        XCTAssertEqual(recorder.components(separatedBy: "PcmChannelWriter(url:").count - 1, 2)
        XCTAssertEqual(recorder.components(separatedBy: "t0: t0)").count - 1, 2, "both channels start at the same t0")
    }

    /// Writers are appended to and closed under one lock.
    /// Mutation: MeetingRecorder, append `self.me?.append` outside `writersLock.withLock` -> RED.
    func testWritersAreGuardedByOneLock() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("self.writersLock.withLock { self.me?.append("))
        XCTAssertTrue(recorder.contains("self.writersLock.withLock { self.them?.append("))
        let stop = try XCTUnwrap(body(recorder, of: "func stop() -> Summary {"))
        XCTAssertTrue(stop.contains("writersLock.withLock {"))
        XCTAssertTrue(stop.contains("me?.finish(atNanos: end)"))
    }

    /// The microphone starts through the tap-safe path, the restart retries, the tap follows route AND rate changes
    /// and retries with the shared policy.
    /// Mutation: MeetingRecorder.startMicrophone, replace `EngineStart.start(` with direct `installTap` -> RED.
    func testTheRecorderStartsAndRestartsSafely() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        let mic = try XCTUnwrap(body(recorder, of: "private func startMicrophone() throws {"))
        XCTAssertTrue(mic.contains("try EngineStart.start(removeTap: { input.removeTap(onBus: 0) }"))
        XCTAssertTrue(recorder.contains("forName: .AVAudioEngineConfigurationChange"))
        XCTAssertTrue(recorder.contains("self.restartMicrophone()"))
        let restart = try XCTUnwrap(body(recorder, of: "private func restartMicrophone() {"))
        XCTAssertTrue(restart.contains("micChain.run()"), "a failed restart tries again, through the generation-guarded chain (#266)")
        XCTAssertTrue(recorder.contains("micChain.begin()"), "a new recording starts a new chain")
        let stopBody = try XCTUnwrap(body(recorder, of: "func stop() -> Summary {"))
        XCTAssertTrue(stopBody.contains("micChain.cancel()"), "the recording that ended takes its pending retry with it")
        XCTAssertFalse(recorder.contains("micRetry"), "no unguarded asyncAfter chain is left")
        let rebuild = try XCTUnwrap(body(recorder, of: "private func scheduleTapRebuild(after delay: TimeInterval) {"))
        XCTAssertTrue(rebuild.contains("self.startTap()"))
        let started = try XCTUnwrap(body(recorder, of: "private func tapStarted(_ outcome: SystemAudioTap.StartOutcome, token: Int) {"))
        XCTAssertTrue(started.contains("case .recovered: onSystemAudioRecovered?()"))
        let failed = started
        XCTAssertTrue(failed.contains("scheduleTapRebuild(after: delay)"))
        // #266: "system audio lost" is told when the old tap no longer delivers (TapLoss). Mutation:
        // MeetingRecorder.tapFailed, replace `sourceLost: lost` with `sourceLost: true` -> RED.
        // The judgement itself is TapRecovery.answer (driven in TapRecoveryTests); the recorder hands it the tap's state and
        // carries the action out. Mutation: MeetingRecorder.tapStarted, `if tellLoss {` -> `if true {` -> RED.
        XCTAssertTrue(failed.contains("tapRecovery.answer(kind, token: token, recording: started != nil, hasTap: tap.isRunning, sinceLastBuffer: silence)"))
        XCTAssertTrue(failed.contains("if tellLoss { onSystemAudioFailed?() }"))
        // Mutation: MeetingRecorder.onSamples, delete `self.tapLastNanos = DispatchTime.now().uptimeNanoseconds` -> RED (the delivery
        // clock never moves); or stamp it with `Date()` again (a wall clock) -> RED.
        XCTAssertTrue(recorder.contains("self.tapLastNanos = DispatchTime.now().uptimeNanoseconds"))
        XCTAssertFalse(recorder.contains("tapLastAt"), "the delivery stamp is monotonic, not a Date")
        XCTAssertTrue(failed.contains("TapLoss.silence(lastNanos: tapLastNanos, nowNanos: DispatchTime.now().uptimeNanoseconds)"))
        // #266: a completion belongs to its recording. Mutation: MeetingRecorder.tapStarted, drop
        // `generation.isCurrent(token)` in TapRecovery.answer -> RED (TapRecoveryTests); the recorder passes its token.
        XCTAssertTrue(started.contains("token: token"))
        XCTAssertTrue(startTapCaptures(recorder))
        XCTAssertEqual(recorder.components(separatedBy: "tapRecovery.begin()").count - 1, 1, "start")
        XCTAssertEqual(recorder.components(separatedBy: "tapRecovery.end()").count - 1, 1, "stop")
        XCTAssertTrue(recorder.contains("kAudioHardwarePropertyDefaultOutputDevice"))
        XCTAssertTrue(recorder.contains("kAudioDevicePropertyNominalSampleRate"))
        XCTAssertTrue(recorder.contains("var useMainSubDevice = true"), "P0a branch A")
    }

    /// A rebuild builds the new tap before the old one is torn down, retries the self-process lookup, and counts.
    /// Mutation: SystemAudioTap.start, move `old.teardown()` before `build(` -> RED.
    func testTheTapBuildsBeforeItTearsDown() throws {
        let tap = try source("OxSayDictation/SystemAudioTap.swift")
        let start = try XCTUnwrap(body(tap, of: "private func startNow(excludingPIDs pids: [pid_t], withMainSubDevice: Bool, epoch requested: Int) throws -> Bool {"))
        let built = try XCTUnwrap(start.range(of: "try build(excluded: excluded, withMainSubDevice: withMainSubDevice)"))
        let torn = try XCTUnwrap(start.range(of: "old.teardown()"))
        XCTAssertLessThan(built.lowerBound, torn.lowerBound)
        XCTAssertFalse(start.contains("stop()"), "no teardown before the new tap runs")
        XCTAssertEqual(start.components(separatedBy: "old.teardown()").count - 1, 1, "the old tap is torn down once, after the new one runs")
        XCTAssertTrue(start.contains("if epoch != requested { return (nil, true) }"), "a stop() that ran meanwhile wins over this start")
        XCTAssertTrue(start.contains("fresh.teardown()"), "...and the tap it built is not left running")
        XCTAssertTrue(start.contains("Retry.firstNonNil(attempts: 4"))
        XCTAssertTrue(start.contains("exclusionMissing += 1"))
        XCTAssertTrue(tap.contains("self.nilBuffers += 1"))
    }

    /// #266: the tap start (it sleeps up to 150 ms looking for this app's audio process) never runs on the main thread:
    /// the recorder asks for it with a completion, the tap does the work on its own control queue.
    /// Mutation: MeetingRecorder.start, call `try tap.startNow(` directly (or any synchronous start) -> RED; SystemAudioTap.start,
    /// run the work without `control.async` -> RED.
    func testTheTapStartsOffTheMainThread() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        let tap = try source("OxSayDictation/SystemAudioTap.swift")
        XCTAssertFalse(recorder.contains("try tap.start("), "no synchronous start from the recorder")
        let startTap = try XCTUnwrap(body(recorder, of: "private func startTap() {"))
        XCTAssertTrue(startTap.contains("tap.start(excludingPIDs: [getpid()], withMainSubDevice: useMainSubDevice)"))
        let start = try XCTUnwrap(body(tap, of: "func start(excludingPIDs pids: [pid_t], withMainSubDevice: Bool, completion: @escaping (StartOutcome) -> Void) {"))
        XCTAssertTrue(start.contains("control.async"))
        XCTAssertTrue(start.contains("DispatchQueue.main.async { completion(outcome) }"))
        XCTAssertTrue(tap.contains("private func startNow("), "the blocking part is private")
        XCTAssertEqual(tap.components(separatedBy: "Thread.sleep").count - 1, 1)
        let now = try XCTUnwrap(body(tap, of: "private func startNow(excludingPIDs pids: [pid_t], withMainSubDevice: Bool, epoch requested: Int) throws -> Bool {"))
        XCTAssertTrue(now.contains("Thread.sleep"), "the only sleep is inside the blocking part")
    }

    /// #270: an aborted start deletes the empty meeting; the retention push at launch logs its failure; the watcher is
    /// told which apps are "Don't record".
    /// Mutation: MeetingController.start, restore `_ = try? await host.client.finishMeeting(id: created.id)` -> RED.
    func testAnAbortedStartDeletesTheEmptyMeetingAndTheRestIsWired() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        let start = try XCTUnwrap(body(controller, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertTrue(start.contains("if let created, current == nil { discardEmpty(created.id) }"))
        XCTAssertFalse(start.contains("finishMeeting"), "no start path closes the empty meeting instead of deleting it")
        let discard = try XCTUnwrap(body(controller, of: "private func discardEmpty(_ id: String) {"))
        XCTAssertTrue(discard.contains("EmptyMeetingCleanup.discard("))
        XCTAssertTrue(discard.contains("client.deleteMeeting(id: id)"))
        XCTAssertTrue(discard.contains("log.error("), "what stays behind is logged")
        let status = try XCTUnwrap(body(controller, of: "func daemonStatusChanged() {\n"))
        XCTAssertFalse(status.contains("try? await"), "the retention push no longer swallows its error")
        XCTAssertTrue(status.contains("retention push at launch failed"))
        XCTAssertTrue(controller.contains("watcher.modeFor = { [weak self] source in"))
        let watcher = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertTrue(watcher.contains("mode: modeFor,"))
    }

    /// #251: the badge keeps its left edge when its width changes while it is on screen.
    /// Mutation: MeetingBadge.update, `resize(keepingPlace: true)` -> `resize(keepingPlace: false)` -> RED.
    func testTheBadgeKeepsItsPlaceWhenTheConsentButtonHides() throws {
        let badge = try source("OxSayDictation/MeetingBadge.swift")
        let update = try XCTUnwrap(body(badge, of: "func update(elapsed: TimeInterval, me: Float, them: Float) {"))
        XCTAssertTrue(update.contains("if changed { resize(keepingPlace: true) }"))
        let layout = try XCTUnwrap(body(badge, of: "private func layout(_ views: [NSView]) {"))
        XCTAssertTrue(layout.contains("resize(keepingPlace: false)"), "new content is centred")
        let resize = try XCTUnwrap(body(badge, of: "private func resize(keepingPlace: Bool) {"))
        XCTAssertTrue(resize.contains("place(anchoredOffset: offset, onScreen: keepingPlace ? placedOn : nil)"))
        let place = try XCTUnwrap(body(badge, of: "private func place(anchoredOffset: Double?, onScreen: UInt32?) {"))
        XCTAssertTrue(place.contains("BadgePlacement.place(screens: screens, placedOn: onScreen"))
    }

    /// #342.4: a display change re-places a badge that is up, on a screen that still exists.
    /// Mutations: MeetingBadge.init, delete the `didChangeScreenParametersNotification` observer -> RED;
    /// `screensChanged`, delete the `place(` line -> RED; its `onScreen: placedOn` -> `onScreen: nil` -> RED; the
    /// `guard panel.isVisible, mode != nil` -> `guard true` -> RED (a hidden badge would reappear).
    func testTheBadgeIsPlacedAgainWhenTheDisplaysChange() throws {
        let badge = try source("OxSayDictation/MeetingBadge.swift")
        XCTAssertTrue(badge.contains("forName: NSApplication.didChangeScreenParametersNotification"))
        XCTAssertTrue(badge.contains("{ [weak self] _ in self?.screensChanged() }"))
        XCTAssertTrue(badge.contains("NotificationCenter.default.removeObserver(screenObserver)"))
        let changed = try XCTUnwrap(body(badge, of: "private func screensChanged() {"))
        XCTAssertTrue(changed.contains("guard panel.isVisible, mode != nil else { return }"))
        XCTAssertTrue(changed.contains("place(anchoredOffset: placedOffset, onScreen: placedOn)"))
        let place = try XCTUnwrap(body(badge, of: "private func place(anchoredOffset: Double?, onScreen: UInt32?) {"))
        XCTAssertTrue(place.contains("placedOn = spot.screenID") && place.contains("placedOffset = spot.offset"))
        XCTAssertTrue(place.contains("panel.setFrameOrigin(NSPoint(x: spot.x, y: spot.y))"))
        XCTAssertFalse(badge.contains("BadgePlacement.originX"), "the position is decided in one place")
        XCTAssertFalse(badge.contains("panel.frame.minX"), "a global x does not survive a change of the arrangement")
    }

    // MARK: controller

    /// The tick is decided by RecordingMonitor and its actions are carried out: stops stop, the silent tap tells.
    /// What a finished meeting announces when it failed is the localized sentence from the daemon's code (the same one the
    /// window shows), never the daemon's English `error`.
    /// Mutation: MeetingController.finished, `host.notify(MeetingFailureNotice.announcement(for: info) ?? L10nKey.meetingFailedGeneric.text)`
    /// -> `host.notify(L10nKey.noticeMeetingFailed.text(info.error ?? ""))` -> RED; the notes variant back to
    /// `else if let error = info.error { host.notify(L10nKey.noticeMeetingFailed.text(error)) }` -> RED.
    func testAFailedMeetingIsAnnouncedInTheUsersWordsNotTheDaemons() throws {
        let finished = try XCTUnwrap(body(try controller(), of: "private func finished(id: String, status: MeetingInfo) async {\n"))
        XCTAssertTrue(finished.contains("host.notify(MeetingFailureNotice.announcement(for: info) ?? L10nKey.meetingFailedGeneric.text)"))
        XCTAssertTrue(finished.contains("} else if let sentence = MeetingFailureNotice.announcement(for: info) {\n                host.notify(sentence)"))
        XCTAssertFalse(finished.contains("info.error"), "the daemon's text never reaches the pill")
        XCTAssertFalse(finished.contains("noticeMeetingFailed"))
    }

    /// Stopping a meeting whose close the daemon refused says it in the user's words (MeetingErrorText), never `"\(error)"`,
    /// which is the daemon's English text for a refusal.
    /// Mutation: MeetingController.stop, `MeetingErrorText.sentence(error, action: .finish)` -> `"\(error)"` -> RED.
    func testAFailedCloseOfTheMeetingIsNotTheDaemonsText() throws {
        let stop = try XCTUnwrap(body(try controller(), of: "    func stop() {\n        guard let (info, _) = current"))
        XCTAssertTrue(stop.contains("host.notify(L10nKey.noticeMeetingFailed.text(MeetingErrorText.sentence(error, action: .finish)))"))
        XCTAssertFalse(stop.contains("\\(error)"))
    }

    /// Mutation: MeetingController.refreshBadge, delete `case .stop(.cap):` handling -> RED.
    func testTheTickCarriesOutTheMonitorsActions() throws {
        let tick = try XCTUnwrap(body(try controller(), of: "@objc private func refreshBadge() {"))
        XCTAssertTrue(tick.contains("for action in monitor.observe(tick) {"))
        XCTAssertTrue(tick.contains("writeFailed: recorder.writeFailed"))
        XCTAssertTrue(tick.contains("case .stop(.diskFull):") && tick.contains("noticeMeetingDiskFull"))
        XCTAssertTrue(tick.contains("case .stop(.cap):") && tick.contains("noticeMeetingCapReached"))
        XCTAssertTrue(tick.contains("case .say(.tapSilent): tellSilentTap()"))
        XCTAssertTrue(tick.contains("case .say(.noSystemAudio): host.notify(L10nKey.noticeMeetingNoSystemAudio.text)"))
        XCTAssertEqual(tick.components(separatedBy: "stop()").count - 1, 2)
    }

    /// The silent-tap notice is NOT modal and its click opens the System Audio Recording pane.
    /// Mutation: MeetingController.tellSilentTap, call `host.alert(` -> RED.
    func testTheSilentTapNoticeIsNotModal() throws {
        let tell = try XCTUnwrap(body(try controller(), of: "private func tellSilentTap() {"))
        XCTAssertFalse(tell.contains("host.alert"))
        XCTAssertFalse(tell.contains("runModal"))
        XCTAssertTrue(tell.contains("host.notify(sentence)"))
        XCTAssertTrue(tell.contains("openURL: URL(string: SystemAudioGuard.settingsURL)"))
        let notifier = try source("OxSayDictation/MeetingNotifier.swift")
        XCTAssertTrue(notifier.contains("NSWorkspace.shared.open(url)"))
    }

    /// Recorder failures reach the monitor and the user; a recovery clears the flag and says so.
    /// Mutation: MeetingController.init, delete `self?.monitor.systemAudioFailed = false` -> RED.
    func testRecorderCallbacksReachTheMonitor() throws {
        let text = try controller()
        XCTAssertTrue(text.contains("self?.monitor.systemAudioFailed = true"))
        XCTAssertTrue(text.contains("self?.monitor.systemAudioFailed = false"))
        XCTAssertTrue(text.contains("noticeMeetingTapRecovered"))
        XCTAssertTrue(text.contains("recorder.onMicrophoneRecovered = { [weak self] in self?.host.notify(L10nKey.noticeMeetingMicRecovered.text) }"))
    }

    /// Sleep ends the recording through the same stop as the button.
    /// Mutation: MeetingController.init, `willSleepNotification` -> `didWakeNotification` -> RED.
    func testSleepStopsTheRecording() throws {
        let text = try controller()
        XCTAssertTrue(text.contains("forName: NSWorkspace.willSleepNotification"))
        let sleep = try XCTUnwrap(body(text, of: "private func stopForSleep() {"))
        XCTAssertTrue(sleep.contains("noticeMeetingSlept"))
        XCTAssertTrue(sleep.contains("\n        stop()\n"))
    }

    /// Quit waits for the daemon on the main thread: the task must not inherit the main actor.
    /// Mutation: MeetingController.stopForQuit, `Task.detached` -> `Task` -> RED.
    func testQuitDoesNotDeadlockItsOwnWait() throws {
        let quit = try XCTUnwrap(body(try controller(), of: "func stopForQuit() {\n"))
        XCTAssertTrue(quit.contains("Task.detached {"))
        XCTAssertTrue(quit.contains("done.wait(timeout: .now() + 3)"))
        XCTAssertTrue(quit.contains("logSummary(recorder.stop(), id: info.id)"))
    }

    /// Mutation: MeetingController.choose, delete `case .editSpeakers(let id): editSpeakers(id)` -> RED.
    func testTheSpeakersMenuIsWired() throws {
        let text = try controller()
        let choose = try XCTUnwrap(body(text, of: "@objc private func choose(_ sender: NSMenuItem) {"))
        XCTAssertTrue(choose.contains("case .editSpeakers(let id): editSpeakers(id)"))
        XCTAssertTrue(choose.contains("case .retryVoices(let id): retryVoices(id)"))
        let open = try XCTUnwrap(body(text, of: "func menuWillOpen() {\n"))
        XCTAssertTrue(open.contains("MeetingMenuRecent.from(list)"))
        let render = try XCTUnwrap(body(text, of: "private func render() {"))
        XCTAssertTrue(render.contains("recent: recent"))
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertTrue(start.contains("speaker: L10nKey.meetingLabelSpeaker.text"))
    }

    /// Every copy goes through the ledger.
    /// Mutation: MeetingController.export, replace `exporter.export(info)` with a direct `NotesExport.write` -> RED.
    func testExportsGoThroughTheLedger() throws {
        let text = try controller()
        XCTAssertTrue(text.contains("MeetingExporter(defaults: host.defaults)"))
        let export = try XCTUnwrap(body(text, of: "private func export(_ info: MeetingInfo)"))
        XCTAssertTrue(export.contains("exporter.export(info)"))
        XCTAssertTrue(export.contains("noticeMeetingCopyKept"))
        XCTAssertTrue(export.contains("noticeMeetingFailed"))
        XCTAssertFalse(text.contains("NotesExport.write"))
    }

    /// Mutation: MeetingController.dontRecordThisOne, delete `watcher.decline()` -> RED.
    func testDeclineAndRecordingStateReachTheWatcher() throws {
        let text = try controller()
        let dont = try XCTUnwrap(body(text, of: "private func dontRecordThisOne() {"))
        XCTAssertTrue(dont.contains("\n        watcher.decline()\n"))
        XCTAssertTrue(text.contains("watcher.recording = { [weak self] in self?.current?.origin }"))
        XCTAssertTrue(text.contains("watcher.themActive = { [weak self] in self?.recorder.themActive ?? false }"))
    }

    /// The watcher decision, the call-start decision, the manual-start gate and the reconcile decision are the policy's.
    /// Mutation: MeetingController.applyCallMode, `MeetingPolicy.watcherShouldRun(` -> `MeetingSettings.callMode(` -> RED.
    /// Mutation (F3): MeetingController.observe, `global: MeetingSettings.callMode(host.defaults)` -> `global: .ask` -> RED.
    func testThePolicyDecidesAtTheCallSites() throws {
        let text = try controller()
        let auto = try XCTUnwrap(body(text, of: "private func applyCallMode() {"))
        XCTAssertTrue(auto.contains("let mode = MeetingSettings.callMode(host.defaults)"))
        XCTAssertTrue(auto.contains("MeetingPolicy.watcherShouldRun(mode: mode, recording: current?.origin)"))
        let stop = try XCTUnwrap(body(text, of: "func stop() {\n"))
        XCTAssertTrue(stop.contains("\n        applyCallMode()\n"), "the watcher is re-evaluated when a recording ends")
        let observe = try XCTUnwrap(body(text, of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("MeetingPolicy.onCallStarted(source: source,"))
        XCTAssertTrue(observe.contains("global: MeetingSettings.callMode(host.defaults)"), "the stored global mode, not a hard-wired one")
        XCTAssertTrue(observe.contains("picked: CallPolicy.pickedMode(for: source, host.defaults)"))
        XCTAssertTrue(observe.contains("installing: host.updateInstalling()"))
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertTrue(start.contains("MeetingPolicy.manualStart(installing: installing) == .waitForInstall"))
        XCTAssertTrue(start.contains("if origin == .auto, installing { return }"))
        let reconcile = try XCTUnwrap(body(text, of: "private func reconcile() {"))
        XCTAssertTrue(reconcile.contains("Reconcile.action(for: m,"))
        XCTAssertTrue(reconcile.contains("currentID: current?.info.id"))
    }

    /// The one-time explanation runs at the first automatic start and at the first Record pressed on the prompt, but a
    /// menu "Record a meeting" is the user's own act and never raises it (the dialog talks about calls, and its first
    /// button would flip the global mode).
    /// Mutation: MeetingController.start, `origin == .auto || offered` -> `true` -> RED.
    func testTheExplanationIsForAutoStartsAndThePromptNotTheMenu() throws {
        let text = try controller()
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertTrue(start.contains("if origin == .auto || offered, !consentReminderAccepted() { return }"))
        XCTAssertTrue(text.contains("start(origin: .manual, source: source, offered: true)"),
                      "the prompt's Record is the offered start")
    }

    /// #342.1 + #348(b): the prompt's Record asks whether the call still looks live before it starts — the
    /// offer's own staleness per OfferLifetime, and for a browser holder a fresh read of ALL its tabs for THIS
    /// call's source. The question is on the badge (no modal mid-call); the decisions are RecordPrompt's
    /// (tested in RecordConfirmTests), the glue is pinned here line by line.
    /// Mutation: badge.onRecord back to `self?.badge.hide(); self?.start(...)` -> RED.
    /// Mutation: `watcher.callTabs(of: bundleID, source: source)` -> `RecordCheck.Tabs.callPage` -> RED.
    func testThePromptsRecordAsksBeforeItStarts() throws {
        let text = try controller()
        XCTAssertTrue(text.contains("badge.onRecord = { [weak self] in self?.recordFromPrompt() }"),
                      "the press routes to the check, not straight to start")
        XCTAssertTrue(text.contains("badge.onConfirmRecord = { [weak self] in self?.answerRecordQuestion(.record) }"))
        XCTAssertTrue(text.contains("badge.onConfirmCancel = { [weak self] in self?.answerRecordQuestion(.cancel) }"),
                      "Cancel is the cancel answer")
        let press = try XCTUnwrap(body(text, of: "private func recordFromPrompt() {"))
        XCTAssertTrue(press.contains("guard case .prompt(let source) = badge.mode else {"))
        XCTAssertTrue(press.contains("start(origin: .manual, source: lastSource, offered: true)"), "never a silent no-op")
        XCTAssertTrue(press.contains("offerLife.stale(now: Date(), offer: .prompt(source: source), liveSource: liveCall?.source)"),
                      "the offer's own staleness, not a second timer")
        XCTAssertTrue(press.contains("let holder = RecordPrompt.holder(bundleID: promptHolder)"), "the holder kind is the pure function's")
        XCTAssertTrue(press.contains("guard holder == .browser, let bundleID = promptHolder else {"))
        XCTAssertTrue(press.contains("watcher.callTabs(of: bundleID, source: source)"), "a fresh all-tab read for this call's source")
        XCTAssertTrue(press.contains("RecordCheck.decide(offerStale: stale, holder: .browser, tabs: tabs)"))
        XCTAssertTrue(press.contains("RecordCheck.decide(offerStale: stale, holder: holder, tabs: .unknown)"))
        XCTAssertTrue(press.contains("badge.showRecordChecking(source: source)"), "the badge stays up during the read")
        XCTAssertFalse(press.contains("badge.hide()"))
        XCTAssertFalse(press.contains("host.alert"), "no modal alert mid-call")
        let answer = try XCTUnwrap(body(text, of: "private func answerRecordQuestion(_ answer: RecordPrompt.Answer) {"))
        XCTAssertTrue(answer.contains("applyRecord(.ask, answer: answer, source: source)"))
        let apply = try XCTUnwrap(body(text, of: "private func applyRecord(_ verdict: RecordCheck.Verdict, answer: RecordPrompt.Answer?, source: String) {"))
        XCTAssertTrue(apply.contains("switch RecordPrompt.outcome(verdict: verdict, answer: answer) {"))
        XCTAssertTrue(apply.contains("case .start: start(origin: .manual, source: source, offered: true)"))
        XCTAssertTrue(apply.contains("case .ask: badge.showRecordConfirm(source: source)"))
        XCTAssertTrue(apply.contains("case .backToPrompt: badge.showPrompt(source: source)"))
        // The question's states count as the prompt for OfferLifetime, which alone takes them down.
        XCTAssertTrue(text.contains("case .prompt(let source)?, .recordChecking(let source)?, .recordConfirm(let source)?: offer = .prompt(source: source)"))
        // The holder is captured when the prompt goes up and the live call is kept per poll: the press may
        // come after the call (and its hold on the mic) ended.
        XCTAssertTrue(text.contains("promptHolder = tick.call?.bundleID"))
        XCTAssertTrue(text.contains("liveCall = tick.call"))
        let callTabs = try XCTUnwrap(body(try source("OxSayDictation/CallWatcher.swift"),
                                          of: "func callTabs(of bundleID: String, source: String) async -> RecordCheck.Tabs {"))
        XCTAssertTrue(callTabs.contains("guard consentFor(bundleID) == .granted else { return .unknown }"),
                      "an undetermined consent sends no Apple Event, and \"cannot tell\" is .unknown, never .callPage")
        XCTAssertTrue(callTabs.contains("BrowserTabURLs.read(bundleID: bundleID, source: source, runner: runner)"))
        XCTAssertTrue(callTabs.contains("dropWhileBusy: true"))
        let watcherText = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertTrue(watcherText.contains("@MainActor\n    func callTabs("), "the per-browser runner table is main-actor only")
        XCTAssertTrue(watcherText.contains("confirmRunners[bundleID] ?? QueuedScriptRunner(label: \"confirm.\\(bundleID)\""))
    }

    /// #340.2: the voices Try Again — the menu's row and the window's button both land in
    /// requestVoicesAgain — asks before it remakes speaker names and notes; a meeting with neither
    /// retries as before. Cancel (not the first button) stops it before the POST.
    /// Mutation: requestVoicesAgain, `== .alertFirstButtonReturn` -> `!=` -> RED.
    func testTheVoicesRetryAsksBeforeItRemakesNamesAndNotes() throws {
        // The signature also matches UnsupportedMeetings' stub — slice from the real controller first.
        let whole = try controller()
        let tail = String(whole[try XCTUnwrap(whole.range(of: "final class MeetingController")).lowerBound...])
        let retry = try XCTUnwrap(body(tail, of: "func requestVoicesAgain(id: String) async throws {"))
        XCTAssertTrue(retry.contains("host.client.meeting(id: id, withTexts: true)"), "the notes' presence is read")
        XCTAssertTrue(retry.contains("host.client.speakers(id: id)"), "the names are read")
        XCTAssertTrue(retry.contains("let asks = VoicesRetry.asksFirst(info: info, speakers: speakers)"))
        XCTAssertTrue(retry.contains("guard VoicesRetry.proceeds(asks: asks, confirmed: {"))
        XCTAssertTrue(retry.contains("host.alert(L10nKey.meetingVoicesRetryRedo.text, L10nKey.meetingVoicesRetryRedoWhy.text,"))
        XCTAssertTrue(retry.contains("[L10nKey.commonRetry.text, L10nKey.commonCancel.text]) == .alertFirstButtonReturn"),
                      "the first button (Try Again) confirms, Cancel does not")
        XCTAssertTrue(retry.contains("}) else { return }"))
        let ask = try XCTUnwrap(retry.range(of: "VoicesRetry.proceeds"))
        let post = try XCTUnwrap(retry.range(of: "host.client.retryMeetingVoices(id: id)"))
        XCTAssertLessThan(ask.lowerBound, post.lowerBound, "the check comes before the POST")
    }

    /// The one-time dialog is a consent reminder: it can cancel this start, and it never writes the global mode or
    /// an app's pick (a user who presses Record for one call must not end up on "Record automatically").
    /// Mutation: MeetingController.consentReminderAccepted, add `MeetingSettings.setCallMode(.auto, host.defaults)` -> RED.
    /// Mutation: same function, `guard pressed == .alertFirstButtonReturn else { return false }` removed -> RED.
    func testTheConsentReminderNeverChangesASetting() throws {
        let reminder = try XCTUnwrap(body(try controller(), of: "private func consentReminderAccepted() -> Bool {"))
        XCTAssertFalse(reminder.contains("setCallMode"), "the reminder must not write the global mode")
        XCTAssertFalse(reminder.contains("CallPolicy.setMode"), "nor a per-app pick")
        XCTAssertFalse(reminder.contains("callMode"))
        // Mutation: MeetingController.consentReminderAccepted, `retention: MeetingSettings.retention(host.defaults)` -> `.month` -> RED.
        XCTAssertTrue(reminder.contains("ConsentReminder.body(retention: MeetingSettings.retention(host.defaults), text: { $0.text })"),
                      "the reminder names the user's retention, not a hardwired one")
        XCTAssertTrue(reminder.contains("guard pressed == .alertFirstButtonReturn else { return false }"), "Don't Record cancels the start")
        XCTAssertTrue(reminder.contains("L10nKey.meetingRemindRecord.text, L10nKey.meetingRemindSkip.text"), "Record This Call is the default button")
        let whole = try controller()
        XCTAssertFalse(whole.contains("Only When I Choose"))
    }

    /// The badge's questions come down through OfferLifetime (Core-tested): the prompt when its call is really
    /// over or another began, the consent question when the browser releases the microphone, and both when the
    /// mode goes Off.
    /// Mutation: MeetingController.observe, `badge.hide()` after `offerLife.verdict(` -> `_ = 0` -> RED.
    /// Mutation: MeetingController.applyCallMode, `badge.hide()` -> `_ = 0` -> RED.
    func testTheOffersComeDownThroughTheCoreDecision() throws {
        let text = try controller()
        let observe = try XCTUnwrap(body(text, of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("if case .hide(let why) = offerLife.verdict(now: Date(), offer: offer, liveSource: tick.call?.source, users: tick.users) {\n            badge.hide()\n"))
        // #342.1/6/7: a prompt withdrawn by the call's absence un-announces its episode.
        // Mutation: MeetingController.observe, delete `if why.withdrawsOffer { watcher.offerWithdrawn() }` -> RED.
        XCTAssertTrue(observe.contains("if why.withdrawsOffer { watcher.offerWithdrawn() }"))
        let apply = try XCTUnwrap(body(text, of: "private func applyCallMode() {"))
        XCTAssertTrue(apply.contains("if !OfferLifetime.offersAllowed(mode: mode) {\n            if case .recording = badge.mode {} else { badge.hide() }"))
    }

    /// "Don't ask for <App>" writes the per-app "Don't record" — reversible in Settings — and declines this call.
    /// Mutation (F6): MeetingController.dontAskForThisApp, delete `CallPolicy.setMode(.never,` -> RED.
    func testDontAskForThisAppStoresTheNever() throws {
        let dont = try XCTUnwrap(body(try controller(), of: "private func dontAskForThisApp() {"))
        XCTAssertTrue(dont.contains("CallPolicy.setMode(.never, for:"))
        XCTAssertTrue(dont.contains("watcher.decline()"))
        XCTAssertTrue(dont.contains("badge.hide()"))
        let text = try controller()
        XCTAssertTrue(text.contains("badge.onDontAsk = { [weak self] in self?.dontAskForThisApp() }"))
    }

    /// The Automation-consent badge is the pre-permission step: the watcher's tab gate is fed the real probe,
    /// the badge offers the in-context Allow…, and Allow… is the first Apple Event.
    /// Mutation (F5): CallWatcher.tick, drop `consent: consentFor` -> RED (undetermined reads its tab directly).
    /// Mutation: MeetingController.observe, `badge.showBrowserConsent(browser: id)` removed -> RED.
    func testTheBrowserConsentBadgeIsTheGate() throws {
        let watcher = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertTrue(watcher.contains("consent: consentFor"), "the observe call carries the consent probe")
        XCTAssertTrue(watcher.contains("AEDeterminePermissionToAutomateTarget(target.aeDesc"))
        XCTAssertTrue(watcher.contains("kAEGetData), false)"), "askUserIfNeeded: false — the probe never prompts")
        let observe = try XCTUnwrap(body(try controller(), of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("badge.showBrowserConsent(browser: id)"))
        let allow = try XCTUnwrap(body(try controller(), of: "private func allowBrowserAutomation() {"))
        XCTAssertTrue(allow.contains("watcher.allowBrowserAutomation(id)"))
        XCTAssertTrue(watcher.contains("_ = readTab(id)"), "Allow… sends the first real Apple Event")
    }

    /// Mutation: CallWatcher.readTab, `dropWhileBusy: true` -> `false` -> RED.
    func testTheWatcherNeverQueuesBehindAStuckRead() throws {
        let watcher = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertTrue(watcher.contains("QueuedScriptRunner(label: bundleID, dropWhileBusy: true)"))
        XCTAssertTrue(watcher.contains("browserNeedsPermission: outcome.browserNeedsPermission"))
        let text = try controller()
        XCTAssertTrue(text.contains("if tick.browserNeedsPermission { host.notify(L10nKey.noticeMeetingBrowserPending.text) }"))
    }

    /// Mutation: MeetingController.ready, delete the `guard !delivered` fallback -> RED.
    func testNotifierFallbackAndCountersAreUsed() throws {
        let text = try controller()
        let ready = try XCTUnwrap(body(text, of: "private func ready(folder: URL?) {"))
        XCTAssertTrue(ready.contains("guard !delivered else { return }"))
        XCTAssertTrue(ready.contains("self?.host.notify(title)"))
        let log = try XCTUnwrap(body(text, of: "private func logSummary("))
        for field in ["meDropped", "mePadded", "themDropped", "themPadded", "failedWrites", "micConversions", "tapConversions",
                      "tapNilBuffers", "tapExclusionMissing"] {
            XCTAssertTrue(log.contains(field), field)
        }
        XCTAssertTrue(text.contains("logSummary(recorder.stop(), id: info.id)"))
    }

    /// Mutation: MeetingController.start, delete the `MeetingRecorder.checkMicrophone()` call -> RED.
    func testTheMicrophoneIsCheckedBeforeAMeetingIsCreated() throws {
        let start = try XCTUnwrap(body(try controller(), of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        let check = try XCTUnwrap(start.range(of: "MeetingRecorder.checkMicrophone()"))
        let create = try XCTUnwrap(start.range(of: "host.client.createMeeting("))
        XCTAssertLessThan(check.lowerBound, create.lowerBound)
    }

    // MARK: X19

    /// #337.1: no error text of the daemon or of a framework reaches a user-visible sink in the meeting code: every
    /// failure is said through MeetingErrorText (or, for a lost audio source, as a fixed notice with the error logged).
    /// Mutation: MeetingController.start, `MeetingErrorText.sentence(error, action: .start)` -> `"\(error)"` -> RED.
    /// Mutation: MeetingController.editSpeakers, the same for `.speakers` -> RED.
    /// Mutation: MeetingController.installModel, `MeetingErrorText.sentence(error, action: .installModel)` -> `StudioError.plain(error)` -> RED.
    func testNoRawErrorTextReachesTheUserFromTheMeetingCode() throws {
        for file in ["OxSayDictation/MeetingController.swift", "OxSayDictation/MeetingRecorder.swift", "DictationCore/RetryChain.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("\"\\(error)\""), "\(file) hands an error's description on as a string")
            XCTAssertFalse(text.contains("StudioError.plain("), "\(file) shows the daemon's own words")
        }
        let text = try controller()
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertEqual(start.components(separatedBy: "L10nKey.noticeMeetingStartFailed.text(MeetingErrorText.sentence(error, action: .start))").count - 1, 2,
                       "the microphone check and the daemon/recorder start both")
        let speakers = try XCTUnwrap(body(text, of: "private func editSpeakers(_ id: String) {"))
        XCTAssertTrue(speakers.contains("L10nKey.speakersFailed.text(MeetingErrorText.sentence(error, action: .speakers))"))
        let install = try XCTUnwrap(body(text, of: "private func installModel() {"))
        XCTAssertTrue(install.contains("host.notify(MeetingErrorText.sentence(error, action: .installModel))"))
        // The real error is logged where the user gets the generic sentence.
        // Mutation: delete the `log.error(` line of any of the four catches -> RED.
        let logLine = "log.error(\"meeting %@ failed: \\(LogDetail.publicText(error), privacy: .public) \\(LogDetail.privateText(error), privacy: .private)\")"
        XCTAssertEqual(start.components(separatedBy: logLine.replacingOccurrences(of: "%@", with: "start")).count - 1, 2)
        XCTAssertTrue(speakers.contains(logLine.replacingOccurrences(of: "%@", with: "speakers")))
        XCTAssertTrue(install.contains(logLine.replacingOccurrences(of: "%@", with: "notes model")))
        XCTAssertTrue(text.contains("recorder.onSystemAudioFailed = { [weak self] in"))
        XCTAssertTrue(text.contains("host.notify(L10nKey.noticeMeetingTapLost.text)"))
        XCTAssertTrue(text.contains("recorder.onMicrophoneFailed = { [weak self] in self?.host.notify(L10nKey.noticeMeetingMicLost.text) }"))
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("var onSystemAudioFailed: (() -> Void)?"))
        XCTAssertTrue(recorder.contains("var onMicrophoneFailed: (() -> Void)?"))
        XCTAssertTrue(recorder.contains("case .failed(let error): kind = .failed; failure = error"))
        let failed = try XCTUnwrap(body(recorder, of: "private func tapStarted(_ outcome: SystemAudioTap.StartOutcome, token: Int) {"))
        XCTAssertTrue(failed.contains("log.error(\"system audio tap: failed: \\(String(describing: failure), privacy: .public)\")"), "the reason goes to the log")
        let chain = try XCTUnwrap(recorder.range(of: "private lazy var micChain = RetryChain("))
        XCTAssertTrue(recorder[chain.lowerBound...].prefix(700).contains("self?.onMicrophoneFailed?()"))
        let mic = try source("OxSayDictation/MeetingRecorder.swift")
        XCTAssertTrue(mic.contains("microphone: restart failed: \\(String(describing: error), privacy: .public)"))
    }

    /// #342.8: the probe maps macOS's status in Core; the watcher logs a browser that has no answer, once per hold.
    /// Mutation: BrowserAutomationProbe.consent, `BrowserConsent.from(status: status)` -> `.granted` -> RED.
    func testTheWatcherPassesTheHeldOnlyFlagAndTheProbeStatusToCore() throws {
        let watcher = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertFalse(watcher.contains("heldOnly"), "no prompt is withdrawn for a browser's hold (#241)")
        XCTAssertTrue(watcher.contains("if let id = outcome.browserNoAnswer {"))
        XCTAssertTrue(watcher.contains("func offerWithdrawn() { watch.offerWithdrawn() }"))
        let probe = try XCTUnwrap(body(watcher, of: "static func consent(bundleID: String) -> BrowserConsent {"))
        XCTAssertTrue(probe.contains("return BrowserConsent.from(status: status)"))
    }

    /// An automatic stop (the tracker's silence rule) says so.
    /// Mutation: MeetingController.observe, delete the notify before `stop()` in `.stopRecording` -> RED.
    func testAnAutomaticStopSaysSo() throws {
        let observe = try XCTUnwrap(body(try controller(), of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("case .stopRecording:\n            host.notify(L10nKey.noticeMeetingCallEnded.text)\n            stop()"))
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        XCTAssertFalse(recorder.contains("anyoneActive"), "the stop rule is the far side's silence, as on main")
    }
}
