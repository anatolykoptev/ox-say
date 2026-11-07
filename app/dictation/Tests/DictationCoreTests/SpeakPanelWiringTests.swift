import Foundation
import XCTest
@testable import DictationCore

/// The panel's AppKit and SwiftUI glue cannot run under the shim; what it decides is in DictationCore (`VoicePanelModel`) and
/// tested there. These read the glue as text, without comments, and pin every call site no behavioural test sees: a deleted
/// call line would leave the suite green (the reviewer of #502 deleted such lines).
final class SpeakPanelWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    func |\n    private func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// A loudness change on a finished project is a delivery with the target and no render, never a new project, and it goes
    /// through the same one-at-a-time gate as every other change (the daemon answers 409 to a second operation).
    /// Mutation: SpeakSource.setLoudness, `loudness: target.lufs` -> `loudness: nil` -> RED.
    func testLoudnessChangeIsADeliveryNotARecreate() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let change = try body(speak, of: "func setLoudness(")
        XCTAssertTrue(change.contains("client.deliver(id: id, entries: [], loudness: target.lufs)"))
        XCTAssertTrue(change.contains("phraseOperation(chunk: PhraseWork.wholeProject, kind: .loudness)"))
        XCTAssertTrue(change.contains("VoicePanelModel.loudnessAppliesNow(status: job.status)"))
        XCTAssertTrue(change.contains("voiceover.followAndWait(id: id)"), "the next read waits for the assemble run")
        for recreate in ["voiceover.start", "startVoiceover", "generateStudio", "SpeakStudio.start"] {
            XCTAssertFalse(change.contains(recreate), "a loudness change must not recreate the project (\(recreate))")
        }
        XCTAssertTrue(change.contains("savePanel()"), "the choice is kept for the next voicing")
    }

    /// Pace, pause and mood for the chosen phrase or the whole text are one batch of delivery entries built by the pure
    /// decision; an empty batch is not sent (the daemon answers 400 to it).
    /// Mutation: SpeakSource.applyDelivery, delete `guard !entries.isEmpty` -> RED.
    func testPaceAndPauseGoOutAsDeliveryEntriesForTheChosenScope() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let apply = try body(speak, of: "private func applyDelivery(")
        XCTAssertTrue(apply.contains("VoicePanelModel.deliveryEntries(chunks: speak.phraseChunks, scope: scope, change: change)"))
        XCTAssertTrue(apply.contains("guard !entries.isEmpty"))
        XCTAssertTrue(apply.contains("speak.phrasesFor == speak.selectedID"), "chunks of another project are never used")
        XCTAssertTrue(apply.contains("client.deliver(id: id, entries: entries, loudness: nil)"))
        XCTAssertTrue(apply.contains("phraseOperation(chunk:"))
        try XCTAssertTrue(body(speak, of: "func setPace(").contains("applyDelivery(.pace(slider), kind: .pace)"))
        try XCTAssertTrue(body(speak, of: "func setPause(").contains("applyDelivery(.pause(seconds), kind: .pause)"))
        try XCTAssertTrue(body(speak, of: "func setPanelMood(").contains("applyDelivery(.mood(mood), kind: .mood)"))
    }

    /// The panel's values reach the fast voice and the studio create through the one merge that ignores them while Advanced is
    /// off; «Ещё вариант» is always a new random sound, the pin or not.
    /// Mutation: SpeakSource.generate, `advanced: model.advanced` -> `advanced: true` -> RED.
    func testThePanelReachesBothVoicesOnlyThroughTheAdvancedGate() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        let fast = try body(speak, of: "func generate(variant: Bool = false) {")
        XCTAssertTrue(fast.contains("VoicePanelModel.speechKnobs(panel: speak.panel, advanced: model.advanced)"))
        XCTAssertTrue(fast.contains("variant ? Int.random(in: 1...999_999_999) : knobs.seed"))
        XCTAssertTrue(fast.contains("speech.speak(text, voice: voice, language: language, seed: seed, loudnessLUFS: knobs.loudness)"))
        let studio = try body(speak, of: "private func generateStudio() {")
        XCTAssertTrue(studio.contains("SpeakStudio.start(text: speak.text, reel: speak.reel, advanced: model.advanced, panel: speak.panel)"))
        XCTAssertTrue(studio.contains("SpeakStudio.copiesRecording(start.options)"))
        XCTAssertTrue(studio.contains("projectCopies.insert(job.id)"))
        // A voice change after the panel's choice never bypasses the merge: the create call has no other source of options.
        XCTAssertTrue(studio.contains("options: start.options"))
    }

    /// The settings are read at start and written at every change.
    /// Mutation: SpeakSource.panelChanged, delete `save(to: host.defaults)` -> RED.
    func testThePanelSettingsAreLoadedAtStartAndSavedOnEveryChange() throws {
        let speak = try source("OxSayDictation/SpeakSource.swift")
        XCTAssertTrue(speak.contains("model.data.speak.panel = VoicePanelSettings.load(from: host.defaults)"))
        try XCTAssertTrue(body(speak, of: "func panelChanged(").contains("savePanel()"))
        try XCTAssertTrue(body(speak, of: "private func savePanel() {").contains("model.data.speak.panel.save(to: host.defaults)"))
    }

    /// The moods of a project that copies the recording's delivery are not offered.
    /// Mutation: SpeakValues.showsMood, drop `copiesRecordingStyle: copiesRecordingStyle` -> RED.
    func testTheMoodChipsKnowWhichProjectsCopyTheRecording() throws {
        let values = try source("MainWindowUI/SpeakValues.swift")
        XCTAssertTrue(values.contains("PhraseEditing.showsMood(voice: selectedID.flatMap { projectVoices[$0] }, voices: voices, advanced: advanced, copiesRecordingStyle: copiesRecordingStyle)"))
        XCTAssertTrue(values.contains("selectedProject.map { projectCopies.contains($0.id) } ?? panel.copiesRecording"))
    }

    /// Every closure the panel calls is assigned in the window source, to the method that carries it out.
    /// Mutation: MainWindowSource, delete the `a.speakLoudness = …` line -> RED.
    func testEveryPanelActionIsWiredToTheSpeakSource() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        for (action, method) in [("speakLoudness", "setLoudness(target)"), ("speakPace", "setPace(value)"), ("speakPause", "setPause(value)"),
                                 ("speakPanelMood", "setPanelMood(mood)"), ("speakPanelChanged", "panelChanged(settings)")] {
            XCTAssertTrue(window.contains("a.\(action) = { [weak self] "), "\(action) is not assigned")
            XCTAssertTrue(window.contains("self?.speakSource.\(method) }"), "\(action) does not reach \(method)")
        }
    }

    /// The toolbar button exists only with Advanced on, and the panel is closed (and stays closed) when Advanced goes off.
    /// Mutation: SpeakPage, delete `if model.advanced {` around the toolbar item -> RED.
    func testThePanelButtonAndThePanelBelongToAdvanced() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains("if model.advanced {"))
        XCTAssertTrue(page.contains("model.speakPanelShown.wrappedValue.toggle()"))
        XCTAssertTrue(page.contains("L10nKey.speakPanelTitle.text"))
        XCTAssertTrue(page.contains(".labelStyle(.titleAndIcon)"))
        XCTAssertTrue(page.contains("SpeakSplit(model: model, panelOpen: model.speakPanelOpen.wrappedValue)"))
        XCTAssertTrue(page.contains("NSSplitViewItem(inspectorWithViewController: panel)"), "the system's own inspector pane")
        XCTAssertTrue(page.contains("controller.setPanel(open: panelOpen, animated: true)"))
        let model = try source("MainWindowUI/MainWindowModel.swift")
        XCTAssertTrue(model.contains("get: { self.data.speak.panelShown && self.advanced }"))
    }

    /// Opening the panel makes room for it through the pure decisions, and closing gives back only what was added.
    /// Mutation: SpeakPage.makeRoom, delete the `window.contentMinSize.width = …` line -> RED.
    func testThePanelMakesRoomForItselfAndGivesItBack() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        let open = try body(page, of: "private func makeRoom(")
        XCTAssertTrue(open.contains("detail: Self.detailMinimum,"), "the least the panes need is the drag floor")
        XCTAssertTrue(open.contains("detail: Self.detailComfortable,"), "the window grows so the text keeps its width")
        XCTAssertTrue(open.contains("window.contentMinSize.width = PanelWindow.minimumWidth(floor: MainWindowSpec.minimumWidth, needed: least, panelOpen: true)"))
        XCTAssertTrue(open.contains("PanelWindow.growth(needed: needed, current: window.contentLayoutRect.width, room: visible.width - window.frame.width)"))
        let close = try body(page, of: "private func giveBackRoom(")
        XCTAssertTrue(close.contains("window.contentMinSize.width = MainWindowSpec.minimumWidth"))
        XCTAssertTrue(close.contains("PanelWindow.shrink(grewBy: grewBy, current: window.contentLayoutRect.width, floor: MainWindowSpec.minimumWidth)"))
        let toggle = try body(page, of: "func setPanel(open: Bool, animated: Bool) {")
        XCTAssertTrue(toggle.contains("if open { makeRoom(animate: animate) } else { giveBackRoom(animate: animate) }"))
    }

    /// Leaving Озвучка with the panel open gives the window its room back and closes the panel for good: the open state lives in
    /// the model and would otherwise outlive the controller that made room for it.
    /// Mutation: SpeakPage.viewWillDisappear, delete `giveBackRoom(animate: false)` -> RED; delete `panelShown = false` -> RED.
    func testLeavingThePageClosesThePanelAndGivesTheRoomBack() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        let leave = try body(page, of: "override func viewWillDisappear() {")
        XCTAssertTrue(leave.contains("giveBackRoom(animate: false)"))
        XCTAssertTrue(leave.contains("panelItem.isCollapsed = true"))
        XCTAssertTrue(leave.contains("model?.data.speak.panelShown = false"))
        XCTAssertTrue(leave.contains("guard let panelItem, !panelItem.isCollapsed else { return }"), "a closed panel has nothing to give back")
    }

    /// The panel draws a row only if `VoicePanelModel.rows` lists it, for the engine of the page, and its captions come from
    /// the timing decision, never a literal.
    /// Mutation: VoicePanel, `if ids.contains("pace")` -> `if true` -> RED.
    func testThePanelDrawsOnlyTheRowsTheModelLists() throws {
        let panel = try source("MainWindowUI/VoicePanel.swift")
        XCTAssertTrue(panel.contains("VoicePanelModel.engine(chosen: values.engine, projectSelected: values.selectedProject != nil)"))
        XCTAssertTrue(panel.contains("SpeakControls.shown(engine: engine, voiceIsDesigned: false, advanced: true, copiesRecordingStyle: values.copiesRecordingStyle)"))
        XCTAssertTrue(panel.contains("VoicePanelModel.rows(controls: controls, engine: engine).map(\\.id)"))
        for id in ["voice", "mood", "pace", "pause", "loudness", "quality", "cloneMode", "seed", "takes"] {
            XCTAssertTrue(panel.contains("if ids.contains(\"\(id)\")"), "row \(id) is not guarded by the model's list")
        }
        XCTAssertTrue(panel.contains("VoicePanelModel.timing(of:"))
        XCTAssertTrue(panel.contains("VoicePanelModel.captionKey(row:"))
        XCTAssertTrue(panel.contains("ForEach(LoudnessTarget.presets"))
        XCTAssertTrue(panel.contains("VoicePanelModel.scope(allText: values.panelAllText, phrase: values.panelPhrase, chunks: values.phraseChunks)"))
    }
}
