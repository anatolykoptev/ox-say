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
        return body.contains("let token = tapGeneration.value") && body.contains("self?.tapStarted(outcome, token: token)")
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
        XCTAssertTrue(started.contains("tapRetry.succeeded()"))
        let failed = try XCTUnwrap(body(recorder, of: "private func tapFailed(_ why: String) {"))
        XCTAssertTrue(failed.contains("scheduleTapRebuild(after: step.delay)"))
        // #266: "system audio lost" is told when the old tap no longer delivers (TapLoss). Mutation:
        // MeetingRecorder.tapFailed, replace `sourceLost: lost` with `sourceLost: true` -> RED.
        XCTAssertTrue(failed.contains("TapLoss.isLost(hasTap: tap.isRunning, sinceLastBuffer: silence, consecutiveFailures: tapRetry.failures + 1)"))
        XCTAssertTrue(failed.contains("tapRetry.failed(sourceLost: lost)"))
        // Mutation: MeetingRecorder.onSamples, delete `self.tapLastAt = Date()` -> RED (the delivery clock never moves).
        XCTAssertTrue(recorder.contains("self.tapLastAt = Date()"))
        // #266: a completion belongs to its recording. Mutation: MeetingRecorder.tapStarted, drop
        // `tapGeneration.isCurrent(token)` -> RED.
        let started2 = try XCTUnwrap(body(recorder, of: "private func tapStarted(_ outcome: SystemAudioTap.StartOutcome, token: Int) {"))
        XCTAssertTrue(started2.contains("guard started != nil, tapGeneration.isCurrent(token) else { return }"))
        XCTAssertTrue(startTapCaptures(recorder))
        XCTAssertEqual(recorder.components(separatedBy: "tapGeneration.advance()").count - 1, 2, "start and stop")
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
        let start = try XCTUnwrap(body(controller, of: "private func start(origin: CallTracker.Origin, source: String) {"))
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
        XCTAssertTrue(watcher.contains("mode: modeFor)"))
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
        XCTAssertTrue(resize.contains("BadgePlacement.originX(anchoredLeft: left"))
    }

    // MARK: controller

    /// The tick is decided by RecordingMonitor and its actions are carried out: stops stop, the silent tap tells.
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
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String) {"))
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
    /// Mutation: MeetingController.applyAutoStart, `MeetingPolicy.watcherShouldRun(` -> `MeetingSettings.autoStart(` -> RED.
    func testThePolicyDecidesAtTheCallSites() throws {
        let text = try controller()
        let auto = try XCTUnwrap(body(text, of: "private func applyAutoStart() {"))
        XCTAssertTrue(auto.contains("MeetingPolicy.watcherShouldRun(autoStart: MeetingSettings.autoStart(host.defaults), recording: current?.origin)"))
        let stop = try XCTUnwrap(body(text, of: "func stop() {\n"))
        XCTAssertTrue(stop.contains("\n        applyAutoStart()\n"), "the watcher is re-evaluated when a recording ends")
        let observe = try XCTUnwrap(body(text, of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("MeetingPolicy.onCallStarted(source: source,"))
        XCTAssertTrue(observe.contains("installing: host.updateInstalling()"))
        let start = try XCTUnwrap(body(text, of: "private func start(origin: CallTracker.Origin, source: String) {"))
        XCTAssertTrue(start.contains("MeetingPolicy.manualStart(installing: installing) == .waitForInstall"))
        XCTAssertTrue(start.contains("if origin == .auto, installing { return }"))
        let reconcile = try XCTUnwrap(body(text, of: "private func reconcile() {"))
        XCTAssertTrue(reconcile.contains("Reconcile.action(for: m,"))
        XCTAssertTrue(reconcile.contains("currentID: current?.info.id"))
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
        let start = try XCTUnwrap(body(try controller(), of: "private func start(origin: CallTracker.Origin, source: String) {"))
        let check = try XCTUnwrap(start.range(of: "MeetingRecorder.checkMicrophone()"))
        let create = try XCTUnwrap(start.range(of: "host.client.createMeeting("))
        XCTAssertLessThan(check.lowerBound, create.lowerBound)
    }
}
