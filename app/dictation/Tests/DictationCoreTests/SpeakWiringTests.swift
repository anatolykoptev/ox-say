import Foundation
import XCTest
@testable import DictationCore

/// Source pins for the Озвучка page's glue (the shim compiles DictationCore only, so the AppKit/SwiftUI files are
/// read as text, without comments). What each decision DOES is tested in SpeakClipsTests, ReachTrackerTests,
/// SpeakPageStateTests and SpeechClientTests; these prove the glue calls the decision from the place that counts.
/// The studio half of controller note 1 (the trimmed script goes to the daemon) is pinned in SpeakStudioWiringTests.
final class SpeakWiringTests: XCTestCase {
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

    /// The fast text goes to the daemon exactly as typed, which is what `SpeakInputCheck` counts: no trimming on the way.
    /// Mutation: SpeakSource.generate, `let text = speak.text` -> `let text = ScriptLimit.script(from: speak.text)` -> RED.
    func testTheFastTextIsSentExactlyAsTypedAndCheckedFirst() throws {
        let generate = try body(source("OxSayDictation/SpeakSource.swift"), of: "func generate(variant: Bool = false) {")
        XCTAssertTrue(generate.contains("let text = speak.text"))
        XCTAssertTrue(generate.contains("speech.speak(text, voice: voice, language: language, seed: seed)"))
        XCTAssertFalse(generate.contains("trimmingCharacters"))
        XCTAssertFalse(generate.contains("ScriptLimit"))
        XCTAssertFalse(generate.contains("SpeechClient.input"))
        let check = try XCTUnwrap(generate.range(of: "SpeakInputCheck.problem(text, engine: .fast"))
        let send = try XCTUnwrap(generate.range(of: "speech.speak("))
        XCTAssertLessThan(check.lowerBound, send.lowerBound, "the text is checked before the round trip")
    }

    /// A request waits while an update installs (the hotkey's gate), and the language is mapped from the script hint.
    /// Mutation: SpeakSource.generate, delete the `host.speechRefusal()` guard -> RED.
    func testAnUpdateHoldsTheRequestAndTheLanguageIsTheDaemonsWord() throws {
        let generate = try body(source("OxSayDictation/SpeakSource.swift"), of: "func generate(variant: Bool = false) {")
        let gate = try XCTUnwrap(generate.range(of: "host.speechRefusal()"))
        let sendAt = try XCTUnwrap(generate.range(of: "speech.speak("))
        XCTAssertLessThan(gate.lowerBound, sendAt.lowerBound)
        XCTAssertTrue(generate.contains("VoicePick.languageHint(of: text).map { VoicePreview.language(locale: $0) }"),
                      "the daemon takes russian/english, not the hint's ru/en")
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("speechRefusal: { UpdateGate.allowsNewDaemonWork(installing: self.updateInstalling) ? nil : L10nKey.noticeUpdatingSpeak.text }"))
        XCTAssertTrue(app.contains("|| (mainWindow.source?.speakBusy ?? false)"), "a version handshake waits for a page request and a clip")
    }

    /// «Остановить» drops the answer: a cancelled request is reported by SpeechClient as an unreachable daemon.
    /// Mutation: SpeakSource.stop, delete `generation.advance()` -> RED.
    func testStopDropsTheAnswerOfTheRequestItLeftBehind() throws {
        let text = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(text, of: "func stop() {").contains("generation.advance()"))
        let generate = try body(text, of: "func generate(variant: Bool = false) {")
        XCTAssertEqual(generate.components(separatedBy: "self.generation.isCurrent(token)").count - 1, 2, "both the answer and the failure are checked")
        XCTAssertTrue(generate.contains("model.data.speak.reach") == false, "reach is recorded through the tracker only")
    }

    /// The recording state is read live at both places a clip can start, and a recording that begins stops the clip
    /// before the hidden-window early return. (The decision itself is `ClipAudioTests`.)
    /// Mutation: SpeakSource.startPlaying, `recordingRunning: false` -> RED; MainWindowSource.recordingChanged, move
    /// `speakSource.recordingStarted()` under `guard visible` -> RED.
    func testAClipNeverSoundsIntoARecording() throws {
        let text = try source("OxSayDictation/SpeakSource.swift")
        let live = "recordingRunning: host.meetings()?.recordingElapsed != nil"
        try XCTAssertTrue(body(text, of: "private func startPlaying(_ clip: SpeakClip) -> Bool {").contains("audio.start(\(live))"))
        try XCTAssertTrue(body(text, of: "func playPause() {").contains("audio.playPause(\(live))"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let rec = try body(window, of: "func recordingChanged() {")
        let stop = try XCTUnwrap(rec.range(of: "speakSource.recordingStarted()"))
        let hidden = try XCTUnwrap(rec.range(of: "guard visible else { return }"))
        XCTAssertLessThan(stop.lowerBound, hidden.lowerBound, "even when the window is hidden")
        XCTAssertTrue(window.contains("speakSource.windowClosed()"))
        XCTAssertTrue(window.contains("self?.speakSource.stopClip(); self?.voiceSource.preview(id)"), "a sample stops the clip")
    }

    /// Every stop releases the version handshake, through the one executor; the players are mutually exclusive.
    /// Mutation: SpeakSource.stopClip, drop `perform(audio.stop())` -> RED; AppDelegate, drop either
    /// `stopSpeakClip()` before `player.play` -> RED; MainWindowSource.playTurn, drop `speakSource.stopClip()` -> RED.
    func testEveryStopReleasesTheHandshakeAndThePlayersExcludeEachOther() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(speak, of: "func stopClip() {").contains("perform(audio.stop())"))
        try XCTAssertTrue(body(speak, of: "private func perform(_ effects: [ClipEffect], track: (() -> Data?)? = nil) {").contains("case .handshakeMayRun:\n                host.workEnded()"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let others = try XCTUnwrap(window.range(of: "speakSource.stopOtherAudio = {"))
        let block = String(window[others.upperBound...].prefix(200))
        XCTAssertTrue(block.contains("voiceSource.stopPreview()") && block.contains("self?.stopPlayback()") && block.contains("host.stopSpeechPlayer()"))
        let playTurn = try body(window, of: "private func playTurn(_ id: String, _ turn: TranscriptTurn) {")
        let clipStop = try XCTUnwrap(playTurn.range(of: "speakSource.stopClip()"))
        let playAt = try XCTUnwrap(playTurn.range(of: "audio.play(url:"))
        XCTAssertLessThan(clipStop.lowerBound, playAt.lowerBound)
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertEqual(app.components(separatedBy: "self.mainWindow.source?.stopSpeakClip()\n").count - 1, 2, "speak-selection and voiceover playback")
        XCTAssertEqual(app.components(separatedBy: "try self.player.play(wav: wav)").count - 1, 2)
    }

    /// The app's speech player is stopped from outside through ONE teardown: `AudioPlayer.stop()` drops the delegate, so
    /// `onFinish` (pill, the voiceover's "ready" dialog after a preview, the handshake) never runs by itself.
    /// Mutation: AppDelegate, `stopSpeechPlayer: ... self.stopSpeechPlayback()` -> `self.player.stop()` -> RED.
    func testEveryStopOfTheSpeechPlayerGoesThroughOneTeardown() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let teardown = try body(app, of: "private func stopSpeechPlayback() {")
        for step in ["playbackDone = nil", "player.stop()", "overlay.finishPlaying()", "handshakeWorkEnded()"] {
            XCTAssertTrue(teardown.contains(step), "the teardown lost `\(step)`")
        }
        XCTAssertTrue(app.contains("overlay.onPlaybackStop = { [weak self] in self?.stopSpeechPlayback() }"))
        XCTAssertTrue(app.contains("stopPlayback: { [unowned self] in self.stopSpeechPlayback() }"))
        XCTAssertTrue(app.contains("stopSpeechPlayer: { [unowned self] in self.stopSpeechPlayback() }"))
        XCTAssertEqual(app.components(separatedBy: "player.stop()").count - 1, 1, "no bare player.stop() outside the teardown")
    }

    /// A player that does not start is a failed start, never a tracked clip; so is a start without its clip.
    /// Mutation: AudioPlayer.play, delete the `guard next.play() else` -> RED; SpeakSource `.start` without clip, drop
    /// `audio.startFailed()` -> RED.
    func testAClipThatNeverStartsIsNotTracked() throws {
        try XCTAssertTrue(source("OxSayDictation/AudioPlayer.swift").contains("guard next.play() else {"))
        let perform = try body(source("OxSayDictation/SpeakSource.swift"), of: "private func perform(_ effects: [ClipEffect], track: (() -> Data?)? = nil) {")
        XCTAssertTrue(perform.contains("guard let wav = track?() else {\n                    audio.startFailed()"))
        try XCTAssertTrue(source("OxSayDictation/SpeakSource.swift").contains("audio.busy(playerIsPlaying: player.isActivelyPlaying)"))
    }

    /// Choosing a clip waits for a running take, and restores only a voice that still exists.
    /// Mutation: SpeakSource.select, drop the `allowsSelection` guard -> RED; use `clip.voice` unchecked -> RED.
    func testSelectWaitsForATakeAndChecksTheVoice() throws {
        let select = try body(source("OxSayDictation/SpeakSource.swift"), of: "func select(_ id: String) {")
        XCTAssertTrue(select.contains("guard model.data.speak.phase.allowsSelection else { return }"))
        XCTAssertTrue(select.contains("SpeakVoice.existing(clip.voice, in: model.data.voices.voices)"))
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains(".disabled(!model.data.speak.phase.allowsSelection)"))
    }

    /// A missed status read keeps the studio note while the tracker waits; the save panel attaches to the main window.
    /// Mutation: SpeakSource.statusRead, `waiting: false` -> RED; SpeakSave back to `NSApp.keyWindow` -> RED.
    func testTheStudioNoteSurvivesOneMissAndTheSavePanelHasItsWindow() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(speak, of: "func statusRead() {").contains("StudioAvailability.held(previous: model.data.speak.studio, status: status, waiting: tracker.waiting)"))
        XCTAssertTrue(speak.contains("SpeakSave.present(clip, in: host.mainWindow())"))
        XCTAssertFalse(speak.contains("NSApp.keyWindow"))
    }

    /// The reach comes from the status read of the refresh pass, after it is awaited, through the tracker.
    /// Mutation: MainWindowSource.refresh, delete `speakSource.statusRead()` -> RED (the page never learns the daemon is gone).
    func testTheStatusReadFeedsTheReachTracker() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let awaited = try XCTUnwrap(window.range(of: "await status.value"))
        let fed = try XCTUnwrap(window.range(of: "speakSource.statusRead()"))
        XCTAssertLessThan(awaited.lowerBound, fed.lowerBound)
        let speak = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(speak, of: "private func record(answered: Bool) {").contains("tracker.record(answered: answered"))
    }

    /// First launch: the sample fills the editor once; the flag is set from `FirstLaunch.claim`'s result.
    /// Mutation: AppDelegate, delete `firstRunPending = openWindowOnFirstLaunch` -> RED.
    func testTheFirstLaunchFillsTheSampleOnce() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("firstRunPending = openWindowOnFirstLaunch"))
        XCTAssertTrue(app.contains("defer { self.firstRunPending = false }"), "true once")
        let speak = try source("OxSayDictation/SpeakSource.swift")
        XCTAssertTrue(speak.contains("SpeakDraft.initial(stored: host.defaults.string(forKey: Self.draftKey)"))
        XCTAssertTrue(speak.contains("firstRun: host.consumeFirstRun()"))
    }

    /// The page asks the decisions and draws nothing the matrix does not list; the install that exists is offered.
    /// Mutation: SpeakPage, drop the `shown.contains(.voice)` condition around the picker -> RED.
    func testThePageDrawsOnlyWhatTheMatrixListsAndOffersTheInstall() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains("SpeakControls.shown(engine: values.engine, voiceIsDesigned: false, advanced: values.advanced)"))
        XCTAssertTrue(page.contains("if shown.contains(.voice) { voicePicker }"))
        XCTAssertTrue(page.contains("if shown.contains(.quality) { quality }"))
        XCTAssertTrue(page.contains("model.actions.installStudioVoice()"), "no pointer to a Settings page that does not exist yet")
        let model = try source("MainWindowUI/MainWindowModel.swift")
        XCTAssertTrue(model.contains("SpeakPageState.of(reach: data.speak.reach"))
        XCTAssertTrue(model.contains("SpeakInputCheck.problem(data.speak.text, engine: data.speak.engine"))
        try XCTAssertTrue(source("MainWindowUI/MainWindowView.swift").contains("case .speak: SpeakPage(model: model)"))
    }
}
