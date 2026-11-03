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
        if let next = rest.dropFirst(signature.count).range(of: "\n    private func |\n    func |\n    @MainActor\n    func |\n    // MARK", options: .regularExpression) {
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
        XCTAssertTrue(designer.contains("flow.submit(taken: libraryNames())"))
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
        XCTAssertTrue(designer.contains("guard mine == self.epoch"), "an answer from a cancelled design is dropped")
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
        XCTAssertTrue(page.contains("model.section = .settings"), "the install link goes to Settings")
        let sheet = try source("MainWindowUI/VoiceDesignSheet.swift")
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.cancelAction)"), "Esc cancels")
        XCTAssertTrue(sheet.contains("Button(L10nKey.designTakeKeep.text) { send(.keep) }.keyboardShortcut(.defaultAction)"), "Return keeps")
        XCTAssertFalse(sheet.contains("runModal"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let actions = try body(window, of: "private func actions() -> MainWindowActions {")
        XCTAssertTrue(actions.contains("a.voiceDesign = "))
    }
}
