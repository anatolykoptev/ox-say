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
        XCTAssertTrue(app.contains("self.mainWindow.source?.recordingChanged()"))
        XCTAssertTrue(app.contains("self.mainWindow.source?.noticeFromApp(message)"))
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

    /// The window asks only while it is open and visible and a meeting (or the download) is still working, every close
    /// or hide stops the clocks, and a refresh does not rebuild the recording clock.
    /// Mutation: MainWindowSource.schedulePolling, `MeetingsPolling.needed(visible: visible, ` -> `MeetingsPolling.needed(visible: true, ` -> RED.
    func testNothingRunsWhileTheWindowIsClosedOrHidden() throws {
        let text = try window()
        let poll = try body(text, of: "private func schedulePolling() {")
        XCTAssertTrue(poll.contains("guard MeetingsPolling.needed(visible: visible, meetings: model.data.meetings, writer: model.data.meetingSettings.notesWriter) else { return }"))
        let stop = try body(text, of: "private func stopClocks() {")
        XCTAssertTrue(stop.contains("visible = false"))
        XCTAssertTrue(stop.contains("pollTask?.cancel()"))
        XCTAssertTrue(stop.contains("clockTimer?.invalidate()"))
        let hoisted1 = try body(text, of: "func windowClosed() {").contains("stopClocks()")
        XCTAssertTrue(hoisted1)
        let hidden = try body(text, of: "func visibilityChanged(_ nowVisible: Bool) {")
        XCTAssertTrue(hidden.contains("guard nowVisible != visible else { return }"))
        XCTAssertTrue(hidden.contains("            refresh()\n"), "shown again, it reads once")
        XCTAssertTrue(hidden.contains("stopClocks()"))
        let sync = try body(text, of: "private func syncRecording() {")
        XCTAssertTrue(sync.contains("guard clockTimer == nil else { return }"), "the clock is not rebuilt on every poll")
        let controller = try source("OxSayDictation/MainWindow.swift")
        XCTAssertTrue(controller.contains("source?.windowClosed()"))
        XCTAssertTrue(controller.contains("source.windowOpened()"), "every open reads the data again")
        XCTAssertTrue(controller.contains("NSWindow.didChangeOcclusionStateNotification"))
        XCTAssertTrue(controller.contains("source?.visibilityChanged(window.occlusionState.contains(.visible) && !window.isMiniaturized)"))
    }

    // MARK: the review's findings

    /// A non-isolated async method runs its second half off the main thread, where the notice closure traps.
    /// The compiler must enforce it: the feature, its protocol and the app delegate are main-actor isolated, and no
    /// `assumeIsolated` papers over a hop.
    /// Mutation: delete `@MainActor` from `final class MeetingController` AND `protocol MeetingFeature` -> RED.
    func testTheMeetingFeatureIsMainActorIsolatedForReal() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        XCTAssertTrue(controller.contains("@MainActor\nprotocol MeetingFeature: AnyObject {"))
        XCTAssertTrue(controller.contains("@MainActor\nfinal class UnsupportedMeetings: MeetingFeature {"))
        XCTAssertTrue(controller.contains("@MainActor\nfinal class MeetingController: NSObject, MeetingFeature {"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("@MainActor\nfinal class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {"))
        let hoisted2 = try source("OxSayDictation/MainWindow.swift").contains("@MainActor\nfinal class MainWindowController: NSObject, NSWindowDelegate {")
        XCTAssertTrue(hoisted2)
        for file in ["MeetingController", "AppDelegate", "MainWindow", "MainWindowSource"] {
            let text = try source("OxSayDictation/\(file).swift")
            XCTAssertFalse(text.contains("assumeIsolated"), file)
        }
    }

    /// Meetings switched off while a start waits for the daemon: nothing records afterwards.
    /// Mutation: MeetingController.start, delete the `if isShutDown {` block after createMeeting -> RED.
    func testSwitchingOffWhileAStartIsWaitingRecordsNothing() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        let start = try body(controller, of: "private func start(origin: CallTracker.Origin, source: String) {")
        let created = try XCTUnwrap(start.range(of: "created = info"))
        let flag = try XCTUnwrap(start.range(of: "if isShutDown {\n                    _ = try? await host.client.finishMeeting(id: info.id)\n                    return\n                }"))
        let recorderStart = try XCTUnwrap(start.range(of: "try recorder.start(into:"))
        XCTAssertLessThan(created.lowerBound, flag.lowerBound)
        XCTAssertLessThan(flag.lowerBound, recorderStart.lowerBound, "checked before the recorder starts")
        XCTAssertTrue(start.contains("guard current == nil, !starting, !isShutDown else { return }"))
        XCTAssertTrue(start.contains("defer { starting = false }"), "starting is reset on that exit too")
        let down = try body(controller, of: "func shutDown() {\n")
        XCTAssertTrue(down.contains("isShutDown = true"))
    }

    /// Mutation: MainWindowSource.refresh, `guard gate.request() else { return }` -> `guard true else { return }`, or drop
    /// `} while gate.finish()` -> RED.
    func testARefreshAskedForDuringARefreshIsNotDropped() throws {
        let refresh = try body(try window(), of: "func refresh() {")
        XCTAssertTrue(refresh.contains("guard gate.request() else { return }"))
        XCTAssertTrue(refresh.contains("} while gate.finish()"))
        XCTAssertTrue(refresh.contains("await host.refreshStatus()"), "the daemon status is read fresh, not what the last menu open saw")
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("refreshStatus: { [unowned self] in await self.refreshServiceStatusNow() }"))
        XCTAssertTrue(app.contains("serviceStatus = status"))
    }

    /// A name typed letter by letter is saved on Return or when the field is left, and never triggers a full read.
    /// Mutation: MainWindowSource.apply, `if change.needsRefresh { refresh() }` -> `refresh()`; or NameField commits in
    /// `.onChange(of: draft)` -> RED.
    func testTheNameFieldKeepsTrailingSpacesAndNeverReloadsMidTyping() throws {
        let apply = try body(try window(), of: "private func apply(_ change: MeetingSettingsModel.Change) {")
        XCTAssertTrue(apply.contains("if change.needsRefresh { refresh() }"))
        XCTAssertFalse(apply.contains("\n            refresh()\n"))
        let page = try source("MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(page.contains(".onSubmit { commit(draft) }"))
        XCTAssertTrue(page.contains(".onChange(of: focused) { isFocused in if !isFocused { commit(draft) } }"))
        XCTAssertTrue(page.contains(".onChange(of: saved) { new in if !focused { draft = new } }"), "a reload never overwrites the focused field")
        XCTAssertFalse(page.contains("TextField(\"\", text: s.yourName"), "no direct binding of the stored name to the field")
    }

    /// Mutation: MainWindowSource.retryNotes, call `host.client.retryMeetingNotes` directly (no `track`) -> RED.
    func testRetryNotesFollowsTheMeetingLikeTheMenuDoes() throws {
        let text = try window()
        XCTAssertTrue(text.contains("try await meetings.retryNotes(id: id)"))
        let controller = try source("OxSayDictation/MeetingController.swift")
        let retry = try body(controller, of: "func retryNotes(id: String) async throws {\n")
        XCTAssertTrue(retry.contains("try await host.client.retryMeetingNotes(id: id)"))
        XCTAssertTrue(retry.contains("track(id)"))
    }

    /// The meeting view asks one Core function what to show for a failure, and shows exactly that: the header sentence
    /// with Try Again, the notes callout with the code's sentence. No view picks a sentence of its own.
    /// Mutation: MeetingDetailView, the callout text back to `info.notesPending == "failed" ? L10nKey.meetingNotesFailed.text : ...` -> RED.
    /// Mutation: MeetingDetailView, the header block restored to `info.status == .failed, let sentence = ...` -> RED.
    /// Mutation: MeetingDetailView, the Try Again button removed or wired to another action -> RED.
    /// Mutation: MeetingDetailView, the Rename gate `.disabled(info.inProgress())` -> `.disabled(!info.settled)` -> RED.
    func testTheMeetingViewShowsTheFailureNoticeAndItsAction() throws {
        let view = try source("MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(view.contains("if let failure = MeetingFailureNotice.of(info), !failure.notes {"))
        XCTAssertTrue(view.contains("Notice(symbol: \"exclamationmark.triangle.fill\", text: failure.sentence, tint: .orange)"))
        XCTAssertTrue(view.contains("if failure.canRetry {\n                    Button(L10nKey.commonRetry.text) { model.actions.retryNotes(info.id) }.controlSize(.small)"))
        XCTAssertTrue(view.contains("let failure = MeetingFailureNotice.of(info).flatMap { $0.notes ? $0 : nil }"))
        XCTAssertTrue(view.contains("Callout(symbol: \"arrow.down.circle\", text: failure?.sentence ?? L10nKey.meetingNotesNeedModel.text) {\n                if failure != nil {"))
        XCTAssertTrue(view.contains("Button(L10nKey.meetingNotesRetry.text) { model.actions.retryNotes(info.id) }"))
        XCTAssertFalse(view.contains("L10nKey.meetingNotesFailed.text"), "the generic notes sentence is the Core's fallback, not the view's")
        XCTAssertFalse(view.contains("failureSentence"), "the view does not build a failure sentence itself")
        XCTAssertTrue(view.contains(".disabled(info.inProgress())"))
        XCTAssertFalse(view.contains(".disabled(!info.settled)"))
    }

    /// Meetings off, or macOS too old: a sentence that says so, never "bad response".
    func testAFeatureThatCannotRunSaysWhy() throws {
        let text = try window()
        XCTAssertEqual(text.components(separatedBy: "throw MeetingFeatureError.switchedOff").count - 1, 4, "rename, speakers, voices, notes")
        let controller = try source("OxSayDictation/MeetingController.swift")
        XCTAssertEqual(controller.components(separatedBy: "throw MeetingFeatureError.needsNewerMacOS").count - 1, 4)
        XCTAssertFalse(controller.contains("throw StudioError.badResponse }\n    func requestVoicesAgain"))
    }

    /// The menu's retention pick goes daemon-first and says a refusal; the window shows an unchecked value as such.
    /// Mutation: MeetingController.choose, store `MeetingSettings.setRetention(pick, host.defaults)` before the request -> RED.
    func testTheMenusRetentionPickGoesThroughTheApplier() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        let choose = try body(controller, of: "@objc private func choose(_ sender: NSMenuItem) {")
        XCTAssertTrue(choose.contains("MeetingSettingsApplier(defaults: host.defaults, client: host.client).apply(.retention(pick))"))
        XCTAssertTrue(choose.contains("host.notify(failure)"))
        XCTAssertFalse(choose.contains("MeetingSettings.setRetention("))
        let hoisted3 = try source("MainWindowUI/SettingsPage.swift").contains("s.wrappedValue.retentionVerified ? L10nKey.settingsKeepFooter.text : L10nKey.settingsKeepUnchecked.text")
        XCTAssertTrue(hoisted3)
    }

    /// A rename leaves the notes-folder copy stale and nothing else re-copies it: the read is retried, then said.
    func testARenameThatCannotRefreshTheCopySaysSo() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        let rename = try body(controller, of: "func rename(id: String, title: String) async throws {\n")
        XCTAssertTrue(rename.contains("for attempt in 1...3 {"))
        XCTAssertTrue(rename.contains("host.notify(L10nKey.noticeMeetingCopyStale.text)"))
    }

    /// A speaker's sample is what a third party said: it is shown verbatim, never read as a LocalizedStringKey (which
    /// parses Markdown, links and images included).
    /// Mutation: MeetingDetailView row, `Text(verbatim: "“\(sp.sample)”")` -> `Text("“\(sp.sample)”")` -> RED.
    func testASpeakersSampleIsShownVerbatim() throws {
        let detail = try source("MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(detail.contains("Text(verbatim: \"“\\(sp.sample)”\")"))
        XCTAssertFalse(detail.contains("Text(\"“\\(sp.sample)”\")"))
    }

    /// Titles the app gave are shown in the user's language; notes and transcript carry no links.
    /// Mutation: MeetingDetailView.inline, `AttributedString(markdown: s, …)` instead of `InlineMarkdown.attributed(s)` -> RED.
    func testTitlesAreLocalizedAndNotesHaveNoLinks() throws {
        let detail = try source("MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(detail.contains("InlineMarkdown.attributed(s)"))
        XCTAssertFalse(detail.contains("AttributedString(markdown"))
        XCTAssertTrue(detail.contains("MeetingRowModel.displayTitle(of: info)"))
        let hoisted4 = try source("MainWindowUI/MeetingsPage.swift").contains("MeetingRowModel.displayTitle(of: info)")
        XCTAssertTrue(hoisted4)
        for page in ["MeetingDetailView", "MeetingsPage", "SettingsPage", "DictationPage", "VoicesPage", "Components"] {
            let text = try source("MainWindowUI/\(page).swift")
            XCTAssertFalse(text.contains("AttributedString(markdown"), page)
        }
    }

    /// The pictures list the real call apps.
    func testTheHarnessListsTheRealCallApps() throws {
        let preview = try source("MainWindowUI/PreviewData.swift")
        XCTAssertTrue(preview.contains("apps: CallPolicy.defaultApps(),"))
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
