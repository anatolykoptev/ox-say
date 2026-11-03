import Foundation
import XCTest
@testable import DictationCore

/// Source pins for «Описать словами» in the window (the shim compiles DictationCore only, so the AppKit and SwiftUI files
/// are read as text, without comments). What each decision does is tested in VoiceDesignFlowTests; these prove the glue
/// carries the decision's result to the daemon and the window, and that the alerts are gone.
final class VoiceDesignWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    private func |\n    func |\n    @MainActor\n    func |\n    @MainActor\n    private func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// PIN, not a behaviour test: after a save the label the person typed is set through the session's rename (a PATCH of
    /// the label) and the list is read through the session. The shim cannot compile VoiceSource.
    /// Mutation: VoiceSource.designSaved, delete the `session.rename(id: voice.name, label: label)` line -> RED (the voice
    /// would appear under its id, the typed label lost); delete `await session.reload()` -> RED.
    func testASavedVoiceGetsItsLabelAndTheListIsReadThroughTheSession() throws {
        let text = try source("OxSayDictation/VoiceSource.swift")
        let saved = try body(text, of: "private func designSaved(")
        XCTAssertTrue(saved.contains("await session.reload()"))
        XCTAssertTrue(saved.contains("session.rename(id: voice.name, label: label)"))
        XCTAssertTrue(saved.contains("DesignForm.savedNotice("))
        XCTAssertTrue(text.contains("designer.saved = "), "the designer's save reaches the window")
        XCTAssertEqual(text.components(separatedBy: "voiceEntries()").count - 1, 1, "the library is read in one place: the session's ops")
    }

    /// The form is told which names exist, from the session's list.
    func testTheFormIsToldWhichNamesExist() throws {
        let text = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(text.contains("designer.libraryNames = "))
        let taken = try body(text, of: "private func takenNames()")
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        XCTAssertTrue(taken.contains("session.entries"))
        XCTAssertTrue(designer.contains("flow.submit(taken: libraryNames(), recordingRunning"))
    }

    /// The effects the flow returns are carried out as they come: the daemon's design and save, the playing, and a
    /// variant never sounds into a recording (VoicePreviewGate through `mayPlay`).
    /// Mutation: VoiceDesigner.play, delete the `guard mayPlay()` -> RED.
    func testTheDesignerCarriesOutTheFlowsEffects() throws {
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        XCTAssertTrue(designer.contains("host.client.designVoice(description: description, text: sentence)"))
        XCTAssertTrue(designer.contains("host.client.saveDesign(name: id, take: take, replace: replace)"))
        let play = try body(designer, of: "private func play(")
        let voiceSource = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(play.contains("guard mayPlay() else"))
        XCTAssertTrue(voiceSource.contains("VoicePreviewGate.allows(recordingRunning: recordingRunning())"))
    }

    /// An answer is applied under the number of the design it was asked for (the flow drops a stale one), not under
    /// whatever design is current when it arrives. Review finding MAJOR-3.
    /// Mutation: VoiceDesigner.design, `flow.designed(takes, for: mine)` -> `for: self.flow.generation` -> RED;
    /// `let mine = flow.generation` captured after the await instead -> RED.
    func testTheDesignerAppliesAnAnswerUnderItsOwnGeneration() throws {
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        let design = try body(designer, of: "private func design(")
        let ask = try XCTUnwrap(design.range(of: "let mine = flow.generation"))
        let call = try XCTUnwrap(design.range(of: "host.client.designVoice("))
        XCTAssertTrue(ask.lowerBound < call.lowerBound, "the number is taken before the request goes out")
        XCTAssertTrue(design.contains("self.flow.designed(takes, for: mine)"))
        XCTAssertTrue(design.contains("self.flow.fail(StudioError.plain(error), for: mine)"))
    }

    /// Only a variant is stopped, and only while it is the last clip the shared player started: closing the window
    /// must not cut a voiceover or a read-aloud. Review finding MAJOR-2.
    /// Mutation: VoiceDesigner.stopVariant, `host.stopPlayback()` called unconditionally -> RED;
    /// `.stopPlayback: stopVariant()` back to `host.stopPlayback()` -> RED; delete `variant.started(` -> RED.
    func testOnlyTheVariantIsEverStopped() throws {
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        let stop = try body(designer, of: "private func stopVariant() {")
        XCTAssertTrue(stop.contains("if variant.mayStop(current: host.playbackSerial()) { host.stopPlayback() }"))
        XCTAssertEqual(designer.components(separatedBy: "host.stopPlayback()").count - 1, 1, "the shared player is stopped in one place")
        XCTAssertTrue(designer.contains("case .stopPlayback: stopVariant()"))
        XCTAssertTrue(designer.contains("variant.started(serial: host.playbackSerial())"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("playbackSerial: { [unowned self] in self.player.serial }"))
        let player = try source("OxSayDictation/AudioPlayer.swift")
        let play = try body(player, of: "func play(wav: Data) throws {")
        XCTAssertTrue(play.contains("serial += 1"), "every clip the player starts is counted")
    }

    /// A saved voice is work until the label and the list are done: the designer ends the flow only after `saved`.
    /// Mutation: VoiceDesigner.save, `_ = self.flow.cancel()` moved before `await self.saved(voice, label)` -> RED.
    func testTheFlowEndsOnlyAfterTheLabelIsSet() throws {
        let save = try body(try source("OxSayDictation/VoiceDesigner.swift"), of: "private func save(")
        let saved = try XCTUnwrap(save.range(of: "await self.saved(voice, label)"))
        let ended = try XCTUnwrap(save.range(of: "_ = self.flow.cancel()"))
        XCTAssertTrue(saved.lowerBound < ended.lowerBound)
    }

    /// «Скачать студийный голос» runs the app's real install; the menu row lands on the page that shows the reason.
    /// Mutation: VoicesPage, the install button back to `model.section = .settings` -> RED.
    func testTheInstallLinkRunsTheInstallAndTheMenuRowLandsOnVoices() throws {
        let page = try source("MainWindowUI/VoicesPage.swift")
        XCTAssertTrue(page.contains("Button(L10nKey.voicesDescribeInstall.text) { model.actions.installStudioVoice() }"))
        XCTAssertFalse(page.contains("model.section = .settings"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let actions = try body(window, of: "private func actions() -> MainWindowActions {")
        XCTAssertTrue(actions.contains("a.installStudioVoice = { [weak self] in self?.host.installStudioVoice() }"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        let host = try body(app, of: "func windowHost() -> MainWindowHost {")
        XCTAssertTrue(host.contains("installStudioVoice: { [unowned self] in self.installStudioVoice() }"))
        let open = try XCTUnwrap(app.range(of: "openVoiceDesign: { [unowned self] in"))
        let tail = String(app[open.lowerBound...].prefix(260))
        let shown = try XCTUnwrap(tail.range(of: "self.mainWindow.show(MainRoute(section: .voices, meetingID: nil))"))
        let sheet = try XCTUnwrap(tail.range(of: "self.mainWindow.source?.openVoiceDesign()"))
        XCTAssertTrue(shown.lowerBound < sheet.lowerBound, "the Voices page is shown first")
        let opener = try body(window, of: "func openVoiceDesign() {")
        XCTAssertTrue(opener.contains("model.data.notice = reason"), "a closed door says why")
    }

    /// The typed text and the recording gate reach the flow. Review findings MINOR-1 and MINOR-4.
    /// Mutation: VoiceDesigner.submit, `recordingRunning: !mayPlay()` dropped -> RED; the sheet's `pushText()` calls dropped -> RED.
    func testTheFormTextAndTheRecordingGateReachTheFlow() throws {
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        XCTAssertTrue(designer.contains("flow.submit(taken: libraryNames(), recordingRunning: !mayPlay())"))
        XCTAssertTrue(designer.contains("flow.playRefused("))
        XCTAssertFalse(designer.contains("flow.fail(L10nKey.voicesPreviewBlockedRecording"))
        let sheet = try source("MainWindowUI/VoiceDesignSheet.swift")
        XCTAssertEqual(sheet.components(separatedBy: "pushText() }").count - 1, 3, "description, sentence and label")
        let voiceSource = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voiceSource.contains("designer.edit(description: description, sentence: sentence, label: label)"))
    }

    /// The Create-a-Voice alerts are gone: no modal, no form dialog, and the menu row opens the window's sheet.
    func testTheAlertsAreGone() throws {
        let designer = try source("OxSayDictation/VoiceDesigner.swift")
        for forbidden in ["host.alert", "runModal", "NSAlert", "designForm"] {
            XCTAssertFalse(designer.contains(forbidden), forbidden)
        }
        let forms = try source("OxSayDictation/StudioForms.swift")
        XCTAssertFalse(forms.contains("NSAlert"))
        XCTAssertFalse(forms.contains("designForm"))
        let controller = try source("OxSayDictation/StudioController.swift")
        XCTAssertTrue(controller.contains("case .createVoice: host.openVoiceDesign()"))
    }

    /// The page: one action closure for the sheet, the button is off unless the studio voice can run, and the sheet is
    /// window-modal (`.sheet`), never a modal run loop.
    func testThePageOffersTheSheetOnlyWhenTheStudioVoiceCanRun() throws {
        let page = try source("MainWindowUI/VoicesPage.swift")
        XCTAssertTrue(page.contains(".disabled(availability != .available)"))
        XCTAssertTrue(page.contains("model.actions.voiceDesign(.open)"))
        XCTAssertTrue(page.contains("VoiceDesignSheet(flow: model.data.voices.design)"))
        XCTAssertTrue(page.contains("model.actions.installStudioVoice()"), "the install link runs the install")
        let sheet = try source("MainWindowUI/VoiceDesignSheet.swift")
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.cancelAction)"), "Esc cancels")
        XCTAssertTrue(sheet.contains("Button(L10nKey.designTakeKeep.text) { send(.keep) }.keyboardShortcut(.defaultAction)"), "Return keeps")
        XCTAssertFalse(sheet.contains("runModal"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let actions = try body(window, of: "private func actions() -> MainWindowActions {")
        XCTAssertTrue(actions.contains("a.voiceDesign = "))
    }
}
