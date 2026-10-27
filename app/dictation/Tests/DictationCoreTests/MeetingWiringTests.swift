import Foundation
import XCTest
@testable import DictationCore

/// The shim compiles DictationCore only, so the AppKit controller and recorder are not testable as code. What they
/// must DO is decided in DictationCore; these tests read the app sources as text (as `AppWorkMeetingTests` does) and
/// pin that the decisions are actually called, each from the place that matters. A mutation that deletes the call
/// leaves every unit test green and makes one of these RED.
final class MeetingWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8)
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

    private func controller() throws -> String { try source("OxSayDictation/MeetingController.swift") }

    // MARK: AppDelegate

    /// Mutation: AppDelegate.appWork(), replace `meetings?.isRecording ?? false` with `false` -> RED.
    func testAppWorkReportsTheLiveRecording() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let work = try XCTUnwrap(body(app, of: "private func appWork() -> VersionHandshake.AppWork {"))
        XCTAssertTrue(work.contains("recordingMeeting: meetings?.isRecording ?? false"), work)
    }

    /// An update install relaunches the app and must not end a recording.
    /// Mutation: AppDelegate.installUpdate, delete the `guard meetings?.isRecording != true` -> RED.
    func testAnInstallNeverStartsUnderARecording() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let install = try XCTUnwrap(body(app, of: "private func installUpdate(tag: String, kind: UpdateInstaller.Kind) {"))
        let guardAt = try XCTUnwrap(install.range(of: "guard meetings?.isRecording != true"))
        let installingAt = try XCTUnwrap(install.range(of: "updateInstalling = true"))
        XCTAssertLessThan(guardAt.lowerBound, installingAt.lowerBound, "the guard must come before the install begins")
    }

    /// Quit closes a recording and hands it to the daemon.
    /// Mutation: AppDelegate.applicationWillTerminate, delete `meetings?.stopForQuit()` -> RED.
    func testQuitStopsARecording() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let quit = try XCTUnwrap(body(app, of: "func applicationWillTerminate(_ notification: Notification) {"))
        XCTAssertTrue(quit.contains("meetings?.stopForQuit()"))
    }

    /// The red dot ends with the recording: the tint must be cleared on the normal path.
    /// Mutation: AppDelegate.applyStatusIcon, delete `statusItem.button?.contentTintColor = nil` -> RED.
    func testTheRedDotEndsWithTheRecording() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let icon = try XCTUnwrap(body(app, of: "private func applyStatusIcon() {"))
        XCTAssertTrue(icon.contains("contentTintColor = .systemRed"))
        XCTAssertTrue(icon.contains("contentTintColor = nil"))
    }

    // MARK: recorder clock (#247)

    /// Every stamp is the buffer's CAPTURE time through HostClock, one t0 for both writers; a second clock
    /// (AudioConvertHostTimeToNanos) or a delivery-time stamp shifts a channel.
    /// Mutation: MeetingRecorder, stamp the mic chunk with `HostClock.nanos(fromHostTicks: AudioGetCurrentHostTime())`
    /// instead of `ticks` -> RED.
    func testTheRecorderStampsCaptureTimeFromOneClock() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        let tap = try source("OxSayDictation/SystemAudioTap.swift")
        XCTAssertFalse(recorder.contains("AudioConvertHostTimeToNanos"))
        XCTAssertFalse(tap.contains("AudioConvertHostTimeToNanos"))
        XCTAssertTrue(recorder.contains("when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime()"))
        XCTAssertTrue(recorder.contains("self.me?.append(samples, atNanos: HostClock.nanos(fromHostTicks: ticks))"))
        XCTAssertTrue(tap.contains("HostClock.nanos(fromHostTicks: time.pointee.mHostTime)"))
        XCTAssertEqual(recorder.components(separatedBy: "PcmChannelWriter(url:").count - 1, 2)
        XCTAssertEqual(recorder.components(separatedBy: "t0: t0)").count - 1, 2, "both channels start at the same t0")
    }

    /// Mutation: MeetingRecorder.start, delete the `if let micObserver` observer registration for
    /// `.AVAudioEngineConfigurationChange` -> RED. And the tap rebuild on an output change.
    func testTheRecorderFollowsRouteChanges() throws {
        let recorder = try source("OxSayDictation/MeetingRecorder.swift")
        XCTAssertTrue(recorder.contains("forName: .AVAudioEngineConfigurationChange"))
        XCTAssertTrue(recorder.contains("try self.startMicrophone()"))
        XCTAssertTrue(recorder.contains("kAudioHardwarePropertyDefaultOutputDevice"))
        XCTAssertTrue(recorder.contains("scheduleTapRebuild()"))
        XCTAssertTrue(recorder.contains("var useMainSubDevice = true"), "P0a branch A")
    }

    // MARK: controller

    /// The first failed write stops and says so.
    /// Mutation: MeetingController.refreshBadge, delete the `if recorder.writeFailed { … stop() }` block -> RED.
    func testTheFirstFailedWriteStopsTheRecording() throws {
        let tick = try XCTUnwrap(body(try controller(), of: "@objc private func refreshBadge() {"))
        let failed = try XCTUnwrap(tick.range(of: "if recorder.writeFailed {"))
        let tail = String(tick[failed.upperBound...])
        let block = String(tail[..<tail.range(of: "}")!.lowerBound])
        XCTAssertTrue(block.contains("noticeMeetingDiskFull"))
        XCTAssertTrue(block.contains("stop()"))
    }

    /// The recording stops at the cap and says so.
    /// Mutation: MeetingController.refreshBadge, delete the `MeetingLimits.reachedCap(elapsed: …)` call -> RED.
    func testTheRecordingStopsAtTheCap() throws {
        let tick = try XCTUnwrap(body(try controller(), of: "@objc private func refreshBadge() {"))
        let cap = try XCTUnwrap(tick.range(of: "if MeetingLimits.reachedCap(elapsed: recorder.elapsed) {"))
        let tail = String(tick[cap.upperBound...])
        let block = String(tail[..<tail.range(of: "}")!.lowerBound])
        XCTAssertTrue(block.contains("noticeMeetingCapReached"))
        XCTAssertTrue(block.contains("stop()"))
    }

    /// The silent-tap decision is asked every tick, with the recorder's numbers, and its verdict is acted on.
    /// Mutation: MeetingController.checkSystemAudio, delete the `case .silentTap:` line's action
    /// (`if told.insert(.silentTap).inserted { tellSilentTap() }`) -> RED.
    func testTheSilentTapVerdictIsActedOn() throws {
        let text = try controller()
        let tick = try XCTUnwrap(body(text, of: "@objc private func refreshBadge() {"))
        XCTAssertTrue(tick.contains("checkSystemAudio()"))
        let check = try XCTUnwrap(body(text, of: "private func checkSystemAudio() {"))
        XCTAssertTrue(check.contains("SystemAudioGuard.assess(sample)"))
        XCTAssertTrue(check.contains("recorder.tapStats"))
        XCTAssertTrue(check.contains("case .silentTap:\n            if told.insert(.silentTap).inserted { tellSilentTap() }"), check)
        let tell = try XCTUnwrap(body(text, of: "private func tellSilentTap() {"))
        XCTAssertTrue(tell.contains("noticeMeetingTapSilent"))
        XCTAssertTrue(tell.contains("SystemAudioGuard.settingsURL"))
        XCTAssertTrue(tell.contains("NSWorkspace.shared.open(url)"))
    }

    /// Sleep ends the recording through the same stop as the button.
    /// Mutation: MeetingController.init, delete the `willSleepNotification` observer -> RED.
    func testSleepStopsTheRecording() throws {
        let text = try controller()
        XCTAssertTrue(text.contains("NSWorkspace.willSleepNotification"))
        let sleep = try XCTUnwrap(body(text, of: "private func stopForSleep() {"))
        XCTAssertTrue(sleep.contains("noticeMeetingSlept"))
        XCTAssertTrue(sleep.contains("stop()"))
    }

    /// Quit waits for the daemon on the main thread: the task must not inherit the main actor.
    /// Mutation: MeetingController.stopForQuit, `Task.detached` -> `Task` -> RED.
    func testQuitDoesNotDeadlockItsOwnWait() throws {
        let quit = try XCTUnwrap(body(try controller(), of: "func stopForQuit() {\n"))
        XCTAssertTrue(quit.contains("Task.detached {"))
        XCTAssertTrue(quit.contains("done.wait(timeout: .now() + 3)"))
    }

    /// The speakers rows open the panel and retry the voices, and the menu knows the recent meetings.
    /// Mutation: MeetingController.choose, delete `case .editSpeakers(let id): editSpeakers(id)` -> RED
    /// (the speakers rows do nothing).
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

    /// Every copy goes through the ledger (`MeetingExporter`), and a staging failure or an edited copy reaches the user.
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

    /// The tracker is told about a decline and a recording the controller ran; a user stop stands (#241).
    /// Mutation: MeetingController.dontRecordThisOne, delete `watcher.decline()` -> RED.
    func testDeclineAndRecordingStateReachTheWatcher() throws {
        let text = try controller()
        let dont = try XCTUnwrap(body(text, of: "private func dontRecordThisOne() {"))
        XCTAssertTrue(dont.contains("watcher.decline()"))
        XCTAssertTrue(text.contains("watcher.recording = { [weak self] in self?.current?.origin }"))
        XCTAssertTrue(text.contains("watcher.themActive = { [weak self] in self?.recorder.themActive ?? false }"))
    }

    /// The call watcher polls through a runner that refuses to queue behind a stuck script (#251) and the
    /// "waiting for permission" notice reaches the user.
    /// Mutation: CallWatcher.readTab, `dropWhileBusy: true` -> `false` -> RED.
    func testTheWatcherNeverQueuesBehindAStuckRead() throws {
        let watcher = try source("OxSayDictation/CallWatcher.swift")
        XCTAssertTrue(watcher.contains("QueuedScriptRunner(label: bundleID, dropWhileBusy: true)"))
        XCTAssertTrue(watcher.contains("browserNeedsPermission: outcome.browserNeedsPermission"))
        let text = try controller()
        XCTAssertTrue(text.contains("if tick.browserNeedsPermission { host.notify(L10nKey.noticeMeetingBrowserPending.text) }"))
    }

    /// The notification falls back to the status line, the converter counters and the clock numbers are logged.
    /// Mutation: MeetingController.ready, delete the `guard !delivered` fallback -> RED.
    func testNotifierFallbackAndCountersAreUsed() throws {
        let text = try controller()
        let ready = try XCTUnwrap(body(text, of: "private func ready(folder: URL?) {"))
        XCTAssertTrue(ready.contains("guard !delivered else { return }"))
        XCTAssertTrue(ready.contains("self?.host.notify(title)"))
        let log = try XCTUnwrap(body(text, of: "private func logSummary("))
        for field in ["meDropped", "mePadded", "themDropped", "themPadded", "failedWrites", "micConversions", "tapConversions"] {
            XCTAssertTrue(log.contains(field), field)
        }
        XCTAssertTrue(text.contains("logSummary(recorder.stop(), id: info.id)"))
    }

    /// The microphone permission is settled before a meeting exists in the daemon.
    /// Mutation: MeetingController.start, delete the `MeetingRecorder.checkMicrophone()` call -> RED.
    func testTheMicrophoneIsCheckedBeforeAMeetingIsCreated() throws {
        let start = try XCTUnwrap(body(try controller(), of: "private func start(origin: CallTracker.Origin, source: String) {"))
        let check = try XCTUnwrap(start.range(of: "MeetingRecorder.checkMicrophone()"))
        let create = try XCTUnwrap(start.range(of: "host.client.createMeeting("))
        XCTAssertLessThan(check.lowerBound, create.lowerBound)
    }
}
