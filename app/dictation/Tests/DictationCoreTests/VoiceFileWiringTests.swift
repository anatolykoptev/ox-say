import Foundation
import XCTest
@testable import DictationCore

/// Source pins for «Взять из файла» in the window (the shim compiles DictationCore only, so the AppKit and SwiftUI
/// files are read as text, without comments). What each decision does is tested in VoiceFileCheckTests and
/// VoiceFileAddTests; these prove the glue carries the model's result to the daemon and the window.
final class VoiceFileWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// PIN, not a behaviour test (the shim cannot compile VoiceSource): the add goes out with `source: "file"`, so the
    /// row lists it under «Из файла» — never "recorded" or empty, which the daemon stores as `.other`.
    /// Mutation F2: VoiceSource.swift `source: "file"` -> `""` -> RED.
    func testTheAddGoesOutAsAFileVoice() throws {
        let submit = try body(try source("OxSayDictation/VoiceSource.swift"), of: "private func submitFile() {")
        XCTAssertTrue(submit.contains(#"source: "file""#), "the add's origin is pinned")
        XCTAssertTrue(submit.contains("client.addVoice(id: request.id, label: request.label,"))
        XCTAssertTrue(submit.contains("audioPath: request.audioPath"), "the clip's absolute path is sent")
        XCTAssertTrue(submit.contains("refText: request.refText"))
    }

    /// PIN: the model decides what may be sent (`submit` holds the check and the taken-name rule), the taken names
    /// are the session's ids and lower-cased labels, and a refused answer lands in the sheet through
    /// `StudioError.plain` — the daemon's own sentence.
    /// Mutation: VoiceSource.submitFile, `draft.submit(taken: takenNames())` -> a label passed straight -> RED;
    /// `StudioError.plain(error)` -> a fixed sentence -> RED.
    func testTheModelDecidesAndTheDaemonSentenceReachesTheSheet() throws {
        let submit = try body(try source("OxSayDictation/VoiceSource.swift"), of: "private func submitFile() {")
        XCTAssertTrue(submit.contains("draft.submit(taken: takenNames())"))
        XCTAssertTrue(submit.contains("fileAdd?.refused(StudioError.plain(error))"))
        let taken = try body(try source("OxSayDictation/VoiceSource.swift"), of: "private func takenNames()")
        XCTAssertTrue(taken.contains("session.entries"))
    }

    /// PIN: after a save the list is read through the session — its sole owner — and the voice's saving sentence is
    /// the notice on top of the page. Mutation: VoiceSource.submitFile, `await session.reload()` deleted -> RED.
    func testASavedFileVoiceReloadsThroughTheSession() throws {
        let submit = try body(try source("OxSayDictation/VoiceSource.swift"), of: "private func submitFile() {")
        XCTAssertTrue(submit.contains("await session.reload()"))
        XCTAssertTrue(submit.contains("DesignForm.savedNotice("))
        let text = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertEqual(text.components(separatedBy: "voiceEntries()").count - 1, 1,
                       "the library is read in one place: the session's ops")
        let sync = try body(text, of: "func sync(")
        XCTAssertTrue(sync.contains("values.file = fileAdd"), "the sheet's model reaches the window")
    }

    /// PIN: the picked file is measured before the sheet shows — its size and its duration through AVURLAsset — and
    /// the clip's absolute path is what the daemon gets (the app is not sandboxed: no security scope needed).
    /// Mutation: VoiceSource.pickFile, `AVURLAsset(url: url)` -> nil seconds -> RED.
    func testThePickedFileIsMeasured() throws {
        let pick = try body(try source("OxSayDictation/VoiceSource.swift"), of: "private func pickFile(")
        XCTAssertTrue(pick.contains("AVURLAsset(url: url)"))
        XCTAssertTrue(pick.contains("attributesOfItem(atPath: path)"))
        XCTAssertTrue(pick.contains("fileName: url.lastPathComponent"))
        XCTAssertTrue(pick.contains("audioPath: path"))
        XCTAssertTrue(pick.contains("ext: url.pathExtension"))
    }

    /// PIN: the actions reach the glue and the page: one `voiceFile` closure, the picker's audio+movie filter, the
    /// sheet on `values.file`, the picked URL handed over, «Взять из файла…» on the page.
    /// Mutation: VoicesPage, `.fileImporter(allowedContentTypes: [.audio, .movie])` narrowed to `[.audio]` -> RED;
    /// MainWindowSource.actions, `a.voiceFile` deleted -> RED.
    func testThePageOpensThePickerAndTheSheet() throws {
        let page = try source("MainWindowUI/VoicesPage.swift")
        XCTAssertTrue(page.contains(".fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio, .movie])"))
        XCTAssertTrue(page.contains("model.actions.voiceFile(.picked(url))"))
        XCTAssertTrue(page.contains("VoiceFileSheet(add: add)"))
        XCTAssertTrue(page.contains("Button(L10nKey.fileOpen.text) { pickingFile = true }"))
        XCTAssertFalse(page.contains("runModal"), "the sheet is window-modal, never a modal run loop")
        let actions = try body(try source("OxSayDictation/MainWindowSource.swift"), of: "private func actions() -> MainWindowActions {")
        XCTAssertTrue(actions.contains("a.voiceFile = "))
    }

    /// PIN: the sheet keeps the typed text alive (Cancel keeps it), «Добавить» is off while the file is refused or
    /// the label is invalid, and Esc reaches the model.
    /// Mutation: VoiceFileSheet, `.disabled(add.fileProblem != nil ...)` dropped -> RED.
    func testTheSheetKeepsTheInputAndGatesTheAdd() throws {
        let sheet = try source("MainWindowUI/VoiceFileSheet.swift")
        XCTAssertEqual(sheet.components(separatedBy: "pushText() }").count - 1, 2, "label and ref text")
        XCTAssertTrue(sheet.contains(".disabled(add.fileProblem != nil || VoiceLabel.clean(label) == nil)"))
        XCTAssertTrue(sheet.contains("Button(L10nKey.fileSheetAdd.text) { send(.add) }"))
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.cancelAction)"), "Esc cancels")
        XCTAssertFalse(sheet.contains("runModal"))
        let source = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(source.contains("fileAdd?.edit(label: label, refText: refText)"))
    }
}
