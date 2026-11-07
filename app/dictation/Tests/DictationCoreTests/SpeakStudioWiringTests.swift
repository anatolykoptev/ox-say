import Foundation
import XCTest
@testable import DictationCore

/// Source pins for the studio half of the Озвучка page (the shim compiles DictationCore only). What each decision DOES
/// is tested in SpeakStudioTests, SpeakListTests, WaveformTests and SpeakRecheckTests; these prove the glue calls it from
/// the place that counts.
final class SpeakStudioWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    private func |\n    func |\n    // MARK|\n    @discardableResult", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// The studio voice sends the trimmed script, checked as the studio counts it, after the update gate.
    /// Mutation: SpeakSource.generateStudio, `script: start.script` -> `script: speak.text` -> RED.
    func testTheStudioCallSiteSendsTheTrimmedScript() throws {
        let studio = try body(source("OxSayDictation/SpeakSource.swift"), of: "private func generateStudio() {")
        XCTAssertTrue(studio.contains("SpeakInputCheck.problem(speak.text, engine: .studio"))
        XCTAssertTrue(studio.contains("let start = SpeakStudio.start(text: speak.text)"))
        XCTAssertTrue(studio.contains("voiceover.start(script: start.script, title: start.title, voice: voice,\n                                                    format: start.format, options: start.options, fromWindow: true)"))
        XCTAssertFalse(studio.contains("script: speak.text"))
        let gate = try XCTUnwrap(studio.range(of: "host.speechRefusal()"))
        let send = try XCTUnwrap(studio.range(of: "voiceover.start("))
        XCTAssertLessThan(gate.lowerBound, send.lowerBound)
        let generate = try body(source("OxSayDictation/SpeakSource.swift"), of: "func generate(variant: Bool = false) {")
        XCTAssertTrue(generate.contains("speak.engine == .studio"), "the engine is the one the page resolved, not the raw choice")
    }

    /// A started voiceover is followed: the handshake and the page's progress both depend on it.
    /// Mutation: VoiceoverService.start, delete `follower.follow(started)` -> RED.
    func testStartedVoiceoverIsFollowed() throws {
        let service = try source("OxSayDictation/VoiceoverService.swift")
        let start = try body(service, of: "func start(script: String")
        let begun = try XCTUnwrap(start.range(of: "client.startVoiceover("))
        let followed = try XCTUnwrap(start.range(of: "follower.follow(started)"))
        XCTAssertLessThan(begun.lowerBound, followed.lowerBound)
        XCTAssertTrue(start.contains("options: options"))
        // The menu starts through the same service, so its job is the page's job.
        let menu = try source("OxSayDictation/StudioController.swift")
        XCTAssertTrue(menu.contains("voiceover.start(script: draft.script"))
        XCTAssertFalse(menu.contains("startVoiceover("), "no second way to start a voiceover that nobody follows")
    }

    /// A followed voiceover holds the version handshake, whichever surface started it.
    /// Mutation: AppDelegate.appWork, `followingVoiceover: studio.voiceover.following` -> `false` -> RED.
    func testFollowedVoiceoverHoldsTheHandshake() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let work = try body(app, of: "private func appWork() -> VersionHandshake.AppWork {")
        XCTAssertTrue(work.contains("followingVoiceover: studio.voiceover.following"))
        XCTAssertTrue(app.contains("voiceover: { [unowned self] in self.studio.voiceover }"))
        try XCTAssertTrue(source("OxSayDictation/VoiceoverService.swift").contains("var following: Bool { follower.following }"))
    }

    /// A project's track sounds through the one player and `ClipAudio`: the same exclusion, handshake release and
    /// recording gate as a clip, and the audio is read only when a start needs it.
    /// Mutation: SpeakSource.playPause, drop `audio.playPause(` for a direct `player.play` -> RED.
    func testAProjectTrackPlaysThroughClipAudioAndPerform() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let play = try body(speak, of: "func playPause() {")
        XCTAssertTrue(play.contains("guard let track = selectedTrack() else { return }"))
        XCTAssertTrue(play.contains("perform(audio.playPause(recordingRunning: host.meetings()?.recordingElapsed != nil), track: track)"))
        XCTAssertEqual(speak.components(separatedBy: "player.play(").count - 1, 1, "one player.play, inside perform")
        let selected = try body(speak, of: "private func selectedTrack() -> (() -> Data?)? {")
        XCTAssertTrue(selected.contains("selectedProject"))
        XCTAssertTrue(speak.contains("options: .mappedIfSafe"), "a long track is mapped, not copied")
        XCTAssertTrue(selected.contains("trackMissing.insert(job.id)"), "a moved file is said, never a crash")
    }

    /// The cursor timer follows `ClipAudio.cursorTicks` from ONE place that runs after every event: `perform` ends with
    /// `syncCursor()` (so a clip that ends on its own, and a stop of one that already ended, still reach it), the end of a
    /// clip and a stop both go through `perform`, and no event arm touches the timer itself. (The rule is
    /// `ClipAudioTests.testTheCursorTicksOnlyWhileTheClipSounds`.)
    /// Mutation: SpeakSource.perform, drop the trailing `syncCursor()` -> RED; StopClip back to a bare player.stop -> RED.
    func testTheCursorTimerFollowsTheSoundInOnePlace() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let perform = try body(speak, of: "private func perform(_ effects: [ClipEffect], track: (() -> Data?)? = nil) {")
        XCTAssertTrue(perform.hasSuffix("        syncCursor()\n    }\n") || perform.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("syncCursor()\n    }"),
                      "the sync runs after the effects, whatever they were (an empty list included)")
        XCTAssertFalse(perform.contains("PositionTicks"), "no event arm starts or stops the timer on its own")
        let sync = try body(speak, of: "private func syncCursor() {")
        XCTAssertTrue(sync.contains("audio.cursorTicks(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"))
        XCTAssertTrue(sync.contains("RunLoop.main.add(timer, forMode: .common)"), "the cursor keeps moving while a menu is open")
        XCTAssertTrue(sync.contains("positionTimer?.invalidate()"))
        XCTAssertTrue(sync.contains("Waveform.fraction(time: self.player.currentTime, duration: self.player.duration)"))
        XCTAssertTrue(speak.contains("self.perform(self.audio.finished())"), "the natural end goes through perform")
        try XCTAssertTrue(body(speak, of: "func stopClip() {").contains("perform(audio.stop())"))
        let view = try source("MainWindowUI/WaveformView.swift")
        XCTAssertTrue(view.contains("accessibilityReduceMotion"))
        XCTAssertTrue(view.contains("playedFraction > 0 && !reduceMotion"), "no cursor under Reduce Motion")
    }

    /// The project list is read after each answered status read and from the follower; the followed job wins.
    /// Mutation: SpeakSource.statusRead, delete `if status != nil { refreshProjects() }` -> RED; apply(), drop the
    /// overlay -> RED.
    func testTheProjectListFollowsTheStatusReadAndTheFollower() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(speak, of: "func statusRead() {").contains("if status != nil { refreshProjects() }"))
        let show = try body(speak, of: "private func show(_ projects: [ProduceJob]) {")
        XCTAssertTrue(show.contains("ensureWaveform()"))
        try XCTAssertTrue(body(speak, of: "private func followedChanged() {").contains("show(SpeakList.overlay(projects: model.data.speak.projects, followed: voiceover.job))"))
        XCTAssertTrue(speak.contains("self.show(SpeakList.afterRead(projects: jobs, followed: self.voiceover.job))"),
                      "a list read is overridden by the follower only while the job still works")
        XCTAssertTrue(speak.contains("onChange: { [weak self] in Task { @MainActor in self?.followedChanged() } }"))
        XCTAssertTrue(speak.contains("onFinish: { [weak self] _ in Task { @MainActor in self?.refreshProjects() } }"))
        XCTAssertTrue(speak.contains("projectReads.isCurrent(token)"), "a late list read never replaces a newer one")
    }

    /// #490: the window's polling consults the Озвучка recheck, and the section change arms it.
    /// Mutation: MainWindowSource.schedulePolling, delete the `speakSource.recheckDelay` term -> RED.
    func testAnOfflineOzvuchkaIsRecheckedByThePollingTimer() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let polling = try body(window, of: "private func schedulePolling() {")
        XCTAssertTrue(polling.contains("speakSource.recheckDelay(visible: visible, section: model.section)"))
        XCTAssertTrue(polling.contains("due.min()"))
        XCTAssertTrue(window.contains("self.schedulePolling()\n                if arrived"), "arriving on the page with the daemon down starts the recheck")
        try XCTAssertTrue(body(source("OxSayDictation/SpeakSource.swift"), of: "func recheckDelay(visible: Bool, section: MainSection) -> TimeInterval? {")
            .contains("SpeakRecheck.delay(visible: visible, section: section, reach: tracker.reach, misses: tracker.misses)"))
    }

    /// A quality the Mac cannot run never reaches the picker as a choice; the studio segment needs `.available`.
    /// Mutation: SpeakPage.quality, `== .available` -> `!= .unknown` -> RED.
    func testTheStudioSegmentIsOfferedOnlyWhereTheStudioCanRun() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains("if model.data.speak.studio == .available {"))
        XCTAssertTrue(page.contains("SpeakProjectState.of(job, serviceWaiting: values.serviceWaiting"))
        try XCTAssertTrue(source("MainWindowUI/MainWindowModel.swift").contains("engine: data.speak.engine"))
    }

    /// A selection that vanishes stops its sound first; the old scan is cancelled when the selection moves; the studio
    /// start flag belongs to its request.
    /// Mutation: SpeakSource.show, drop `stopClip()` -> RED; newText, drop `cancelWaveform()` -> RED; generateStudio back
    /// to a bare `startingStudio = true` -> RED.
    func testSelectionChangesStopSoundAndScansAndTheStartFlagIsOwned() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let show = try body(speak, of: "private func show(_ projects: [ProduceJob]) {")
        let stop = try XCTUnwrap(show.range(of: "stopClip()"))
        let clear = try XCTUnwrap(show.range(of: "model.data.speak.selectedID = nil"))
        XCTAssertLessThan(stop.lowerBound, clear.lowerBound, "the sound stops before the selection is dropped")
        XCTAssertTrue(show.contains("SpeakList.stillPresent("))
        let cancel = try body(speak, of: "private func cancelWaveform() {")
        for step in ["waveformReads.advance()", "waveformTask?.cancel()", "waveformTask = nil"] { XCTAssertTrue(cancel.contains(step), step) }
        try XCTAssertTrue(body(speak, of: "func newText() {").contains("cancelWaveform()"))
        let ensure = try body(speak, of: "private func ensureWaveform() {")
        XCTAssertTrue(ensure.contains("if waveformKey != nil { cancelWaveform() }"), "no track: the scan of the last one stops")
        XCTAssertTrue(ensure.contains("SpeakTrack.key(projectID: job.id, path: path, modified:"), "keyed on the file, so a re-render reloads")
        XCTAssertTrue(ensure.contains("withTaskCancellationHandler"))
        XCTAssertTrue(speak.contains("private var studioStart = StartingGate()"))
        XCTAssertTrue(speak.contains("studioStart.begin(token)"))
        XCTAssertFalse(speak.contains("startingStudio = true"))
        XCTAssertFalse(speak.contains("startingStudio = false"))
        let newText = try body(speak, of: "func newText() {")
        XCTAssertTrue(newText.contains("if startingStudio {\n            generation.advance()\n            studioStart.end()"))
    }

    /// The finish alert is skipped for a page project with the window in view; the menu's stop and battery actions go
    /// through the one service; arriving on Озвучка offline reads at once; the list is cached, not re-merged per redraw.
    /// Mutation: StudioController, drop the `FinishNotice.shouldAlert` guard -> RED; MainWindowSource, drop
    /// `if arrived { self.refresh() }` -> RED; SpeakValues, `items` back to a computed merge -> RED.
    func testTheMenuAndTheWindowShareTheServiceAndTheArrivalReads() throws {
        let menu = try source("OxSayDictation/StudioController.swift")
        XCTAssertTrue(menu.contains("FinishNotice.shouldAlert(startedOnPage: self.voiceover.startedOnPage(job.id)"))
        XCTAssertTrue(menu.contains("windowVisible: self.host.windowVisible()"))
        XCTAssertTrue(menu.contains("try await self?.voiceover.stop()"))
        XCTAssertTrue(menu.contains("try await self?.voiceover.continueOnBattery()"))
        XCTAssertFalse(menu.contains("host.client.stopVoiceover"))
        try XCTAssertTrue(source("OxSayDictation/AppDelegate.swift").contains("window.isVisible && window.occlusionState.contains(.visible)"))
        try XCTAssertTrue(source("OxSayDictation/VoiceoverService.swift").contains("if fromWindow { windowStarted.insert(started.id) }"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("SpeakRecheck.refreshOnArrival(to: self.model.section, from: self.lastSection, reach: self.speakSource.reach)"))
        XCTAssertTrue(window.contains("if arrived { self.refresh() }"))
        let values = try source("MainWindowUI/SpeakValues.swift")
        XCTAssertEqual(values.components(separatedBy: "didSet { items = SpeakList.merge(projects: projects, clips: clips) }").count - 1, 2)
        XCTAssertTrue(values.contains("public private(set) var items: [SpeakListItem]"))
    }
}
