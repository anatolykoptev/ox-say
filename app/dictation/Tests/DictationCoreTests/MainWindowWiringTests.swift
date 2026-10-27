import Foundation
import XCTest
@testable import DictationCore

/// The shim compiles DictationCore only, so the window's AppKit glue is read as text, WITHOUT its comments, and pinned
/// to the exact expression that matters. What each decision DOES is tested in DictationCore; these prove the glue calls
/// it from the place that counts. Each test names the mutation that must turn it red.
final class MainWindowWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    private func window() throws -> String { try source("OxSayDictation/MainWindowSource.swift") }

    /// The window shows what the daemon and the stores hold, never sample data.
    /// Mutation: MainView, `MainWindowModel(data: PreviewData.make())` instead of `source.model` -> RED.
    func testTheWindowIsNotFedSampleData() throws {
        let view = try source("OxSayDictation/MainView.swift")
        XCTAssertFalse(view.contains("PreviewData"))
        XCTAssertTrue(view.contains("MainWindowView(model: source.model)"))
        let w = try window()
        XCTAssertFalse(w.contains("PreviewData"))
    }

    /// The recording bar reads the meeting feature itself, and Stop is the feature's own stop.
    /// Mutation: MainWindowSource.syncRecording, `host.meetings()?.recordingElapsed` -> `nil` (or Stop calls anything but `stop()`) -> RED.
    func testTheRecordingBarIsDrivenByTheMeetingController() throws {
        let text = try window()
        let sync = try body(text, of: "private func syncRecording() {")
        XCTAssertTrue(sync.contains("model.data.recordingElapsed = host.meetings()?.recordingElapsed"))
        XCTAssertTrue(sync.contains("self.model.data.recordingElapsed = self.host.meetings()?.recordingElapsed"), "the clock keeps reading it")
        XCTAssertTrue(text.contains("a.stopRecording = { [weak self] in self?.host.meetings()?.stop() }"))
        XCTAssertTrue(text.contains("a.startRecording = { [weak self] in self?.host.meetings()?.startRecording() }"))
        let controller = try source("OxSayDictation/MeetingController.swift")
        XCTAssertTrue(controller.contains("var recordingElapsed: TimeInterval? { current == nil ? nil : recorder.elapsed }"))
        XCTAssertTrue(controller.contains("case .stopMeeting: stop()"), "the menu's Stop is the same function")
    }

    /// A started or stopped recording reaches the window; a closed window is not touched.
    /// Mutation: AppDelegate.setUpMeetings, delete `self.mainWindow.source?.recordingChanged()` -> RED.
    func testTheAppTellsTheWindowAboutTheRecording() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("MainActor.assumeIsolated { self.mainWindow.source?.recordingChanged() }"))
        XCTAssertTrue(app.contains("MainActor.assumeIsolated { self.mainWindow.source?.noticeFromApp(message) }"))
        let changed = try body(try window(), of: "func recordingChanged() {")
        XCTAssertTrue(changed.contains("guard visible else { return }"))
    }

    /// The sound mode is saved through `DictationSettings.setSound` (-> `choose`), never by writing the key, and the
    /// menu's check marks follow.
    /// Mutation: MainWindowSource.actions, `DictationSettings.setSound(mode, self.host.defaults)` ->
    /// `self.host.defaults.set(mode.rawValue, forKey: SoundWhileDictatingSetting.defaultsKey)` -> RED.
    func testTheSoundModeGoesThroughChoose() throws {
        let text = try window()
        XCTAssertTrue(text.contains("DictationSettings.setSound(mode, self.host.defaults)"))
        XCTAssertTrue(text.contains("self.host.soundChanged()"))
        XCTAssertFalse(text.contains("defaultsKey"), "no direct write of the sound key from the window")
        XCTAssertFalse(text.contains("soundWhileDictating\""))
        let core = try source("DictationCore/MeetingSettingsModel.swift")
        XCTAssertTrue(core.contains("SoundWhileDictatingSetting.choose(mode, in: d)"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("soundChanged: { [unowned self] in self.syncSoundModeItems() }"))
        XCTAssertTrue(app.contains("SoundWhileDictatingSetting.choose(mode, in: .standard)"), "the menu still uses choose")
    }

    /// A delete the daemon refused is shown; the meeting stays in the list.
    /// Mutation: MainWindowSource.delete, `case .failed(let sentence): model.data.notice = sentence` -> `case .failed: break` -> RED.
    func testARefusedDeleteIsShown() throws {
        let delete = try body(try window(), of: "private func delete(_ id: String) {")
        XCTAssertTrue(delete.contains("switch await service.delete(id: id) {"))
        XCTAssertTrue(delete.contains("case .failed(let sentence):\n                model.data.notice = sentence"))
    }

    /// A setting the daemon did not take is said and the page shows the stored value again.
    /// Mutation: MainWindowSource.apply, delete the `model.data.notice = failure` line -> RED.
    func testASettingThatFailedToSaveIsSaidAndReverted() throws {
        let apply = try body(try window(), of: "private func apply(_ change: MeetingSettingsModel.Change) {")
        XCTAssertTrue(apply.contains("MeetingSettingsApplier(defaults: host.defaults, client: host.client)"))
        XCTAssertTrue(apply.contains("if let failure = await applier.apply(change) {\n                model.data.notice = failure\n                await reloadSettingsAsync()\n                return"))
        XCTAssertTrue(apply.contains("case .enabled: host.meetingsEnabledChanged()"))
        XCTAssertTrue(apply.contains("case .autoStart: host.meetings()?.settingsChanged()"))
    }

    /// Rename and speakers go through the meeting feature, which also refreshes the notes-folder copy; the menu's panel
    /// uses the very same function.
    /// Mutation: MainWindowSource.rename, call `host.client.renameMeeting` directly -> RED.
    func testRenameAndSpeakersShareTheMenusFollowUp() throws {
        let text = try window()
        XCTAssertTrue(text.contains("try await meetings.rename(id: id, title: title)"))
        XCTAssertTrue(text.contains("try await meetings.saveSpeakers(id: id, edits: edits)"))
        XCTAssertTrue(text.contains("try await meetings.requestVoicesAgain(id: id)"))
        XCTAssertFalse(text.contains("renameMeeting(id:"), "the window does not bypass the controller")
        let controller = try source("OxSayDictation/MeetingController.swift")
        XCTAssertTrue(controller.contains("state = try await saveSpeakers(id: id, edits: edits)"), "the menu's panel saves through the same function")
        let save = try body(controller, of: "func saveSpeakers(id: String, edits: SpeakerEdits) async throws -> SpeakersState {\n")
        XCTAssertTrue(save.contains("MeetingSettings.setExportStale(id, true, host.defaults)"))
        XCTAssertTrue(save.contains("if state.notesQueued {"))
        let rename = try body(controller, of: "func rename(id: String, title: String) async throws {\n")
        XCTAssertTrue(rename.contains("try await host.client.renameMeeting(id: id, title: title)"))
        XCTAssertTrue(rename.contains("export(info)"), "the copy in the notes folder follows the new title through the ledger")
    }

    /// The only clipboard write of the window is Copy as Markdown, from the user's click.
    /// Mutation: add any other `NSPasteboard` use to MainWindowSource -> RED.
    func testCopyAsMarkdownIsTheOnlyClipboardWrite() throws {
        let text = try window()
        XCTAssertEqual(text.components(separatedBy: "NSPasteboard").count - 1, 2, "clearContents and setString of the one copy")
        let copy = try body(text, of: "private func copyNotes(_ id: String) {")
        XCTAssertTrue(copy.contains("NSPasteboard.general.setString(markdown, forType: .string)"))
        XCTAssertTrue(copy.contains("model.data.details[id]?.info.notesMD"))
        XCTAssertFalse(text.contains("a.copyNotes = { [weak self] id in self?.copyNotes(id) }\n        a.copyDictation"))
        for page in ["DictationPage", "VoicesPage", "SettingsPage", "MeetingsPage", "MeetingDetailView"] {
            let ui = try source("MainWindowUI/\(page).swift")
            XCTAssertFalse(ui.contains("NSPasteboard"), page)
        }
    }

    /// The window asks only while it is open and a meeting is still working, and every close stops the clocks.
    /// Mutation: MainWindowSource.schedulePolling, `MeetingsPolling.needed(visible: visible, ` -> `MeetingsPolling.needed(visible: true, ` -> RED.
    func testNothingRunsWhileTheWindowIsClosed() throws {
        let text = try window()
        let poll = try body(text, of: "private func schedulePolling() {")
        XCTAssertTrue(poll.contains("guard MeetingsPolling.needed(visible: visible, meetings: model.data.meetings) else { return }"))
        let closed = try body(text, of: "func windowClosed() {")
        XCTAssertTrue(closed.contains("visible = false"))
        XCTAssertTrue(closed.contains("pollTask?.cancel()"))
        XCTAssertTrue(closed.contains("clockTimer?.invalidate()"))
        let controller = try source("OxSayDictation/MainWindow.swift")
        XCTAssertTrue(controller.contains("MainActor.assumeIsolated { source?.windowClosed() }"))
        XCTAssertTrue(controller.contains("MainActor.assumeIsolated { source.windowOpened() }"), "every open reads the data again")
    }

    /// A call from an app set to "Don't record" is neither recorded nor offered.
    /// Mutation: MeetingController.observe, delete `case .ignore: break` or pass `mode: .ask` -> RED (or no build).
    func testThePerAppPickReachesTheCallDecision() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        let observe = try body(controller, of: "private func observe(_ tick: CallWatcher.Tick) {")
        XCTAssertTrue(observe.contains("mode: CallPolicy.mode(for: source, host.defaults)"))
        XCTAssertTrue(observe.contains("case .ignore: break"))
        XCTAssertTrue(observe.contains("installing: host.updateInstalling()"))
    }

    /// Meetings are switched on and off for real: the feature, its menu row and the icon, and a recording stops first.
    /// Mutation: AppDelegate.applyMeetingsEnabled, delete `current.shutDown()` -> RED.
    func testSwitchingMeetingsOffTearsTheFeatureDown() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let apply = try body(app, of: "private func applyMeetingsEnabled() {")
        XCTAssertTrue(apply.contains("current.shutDown()"))
        XCTAssertTrue(apply.contains("meetings = nil"))
        XCTAssertTrue(apply.contains("statusItem.menu?.removeItem(item)"))
        XCTAssertTrue(apply.contains("menu.insertItem(item, at: after)"))
        XCTAssertTrue(apply.contains("applyStatusIcon()"))
        XCTAssertTrue(app.contains("meetingsEnabledChanged: { [unowned self] in self.applyMeetingsEnabled() }"))
        let controller = try source("OxSayDictation/MeetingController.swift")
        let down = try body(controller, of: "func shutDown() {\n")
        XCTAssertTrue(down.contains("if current != nil { stop() }"))
        XCTAssertTrue(down.contains("watcher.stop()"))
        XCTAssertTrue(down.contains("NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)"))
        XCTAssertTrue(app.contains("@objc private func openMainWindow() {\n        mainWindow.open()\n    }"), "Open OxSay… opens the window")
    }

    /// The one Settings write that reaches the daemon must not be the menu's swallowing `try?` for the window's pick.
    func testTheWindowReadsTheDaemonsRetention() throws {
        let text = try window()
        XCTAssertTrue(text.contains("let daemon = try? await host.client.meetingDaemonSettings()"))
        XCTAssertTrue(text.contains("daemonRetention: daemon?.retention"))
    }

    /// The Show in Finder target is DictationCore's decision over the ledger and the notes folder.
    func testShowInFinderUsesTheLedger() throws {
        let open = try body(try window(), of: "private func openFolder(_ id: String) {")
        XCTAssertTrue(open.contains("exportPath: MeetingSettings.exportPath(id, host.defaults)"))
        XCTAssertTrue(open.contains("case .nowhere: model.data.notice = L10nKey.meetingFolderNone.text"))
    }
}
