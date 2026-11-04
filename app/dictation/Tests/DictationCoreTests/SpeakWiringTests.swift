import Foundation
import XCTest
@testable import DictationCore

/// Source pins for the Озвучка page's glue (the shim compiles DictationCore only, so the AppKit/SwiftUI files are
/// read as text, without comments). What each decision DOES is tested in SpeakClipsTests, ReachTrackerTests,
/// SpeakPageStateTests and SpeechClientTests; these prove the glue calls the decision from the place that counts.
/// The studio half of controller note 1 (the trimmed script goes to `ProduceRequest.createBody`) is Task 15's pin:
/// this page has no studio path yet.
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

    /// A recording captures the output: a clip never starts into one, and a recording that begins stops it.
    /// Mutation: SpeakSource.allowedToSound, delete the `VoicePreviewGate.allows` guard -> RED.
    func testAClipNeverSoundsIntoARecording() throws {
        let text = try source("OxSayDictation/SpeakSource.swift")
        try XCTAssertTrue(body(text, of: "private func allowedToSound() -> Bool {")
            .contains("VoicePreviewGate.allows(recordingRunning: host.meetings()?.recordingElapsed != nil)"))
        try XCTAssertTrue(body(text, of: "private func startPlaying(_ clip: SpeakClip) -> Bool {").contains("allowedToSound()"))
        try XCTAssertTrue(body(text, of: "func playPause() {").contains("allowedToSound()"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("speakSource.recordingStarted()"))
        XCTAssertTrue(window.contains("speakSource.windowClosed()"))
        XCTAssertTrue(window.contains("self?.speakSource.stopClip(); self?.voiceSource.preview(id)"), "a sample stops the clip")
        XCTAssertTrue(window.contains("speakSource.stopVoicePreview = { [weak self] in self?.voiceSource.stopPreview() }"), "a clip stops the sample")
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
        XCTAssertTrue(page.contains("SpeakControls.shown(engine: .fast, voiceIsDesigned: false, advanced: values.advanced)"))
        XCTAssertTrue(page.contains("if shown.contains(.voice) { voicePicker }"))
        XCTAssertTrue(page.contains("if shown.contains(.quality) { quality }"))
        XCTAssertTrue(page.contains("model.actions.installStudioVoice()"), "no pointer to a Settings page that does not exist yet")
        let model = try source("MainWindowUI/MainWindowModel.swift")
        XCTAssertTrue(model.contains("SpeakPageState.of(reach: data.speak.reach"))
        XCTAssertTrue(model.contains("SpeakInputCheck.problem(data.speak.text, engine: .fast"))
        try XCTAssertTrue(source("MainWindowUI/MainWindowView.swift").contains("case .speak: SpeakPage(model: model)"))
    }
}
