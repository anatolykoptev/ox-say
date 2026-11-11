import XCTest
@testable import DictationCore

/// Source pins for the Расшифровка page's glue (the shim compiles DictationCore only; the AppKit/SwiftUI files are read as
/// text, without comments). What each decision does is tested in TranscribeSessionTests; these prove the glue calls it from the
/// place that counts.
final class TranscribeWiringTests: XCTestCase {
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

    /// An upload or a running transcription holds a pending relaunch.
    /// Mutation: AppDelegate.appWork, `transcribing:` -> `false` -> RED.
    func testTranscribingHoldsTheHandshake() throws {
        let busy = VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                            recordingMeeting: false, transcribing: true)
        XCTAssertFalse(busy.idle)
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                               recordingMeeting: false).idle)
        let app = try source("OxSayDictation/AppDelegate.swift")
        let work = try body(app, of: "private func appWork() -> VersionHandshake.AppWork {")
        XCTAssertTrue(work.contains("transcribing: mainWindow.source?.transcribing ?? false"), work)
    }

    /// The page asks before it deletes; the app's delete is reachable only from the confirm button.
    /// Mutation: TranscribePage, call `model.actions.transcribeDelete(entry.id)` from the menu row -> RED.
    func testDeleteWaitsForTheConfirmation() throws {
        let page = try source("MainWindowUI/TranscribePage.swift")
        XCTAssertEqual(page.components(separatedBy: "transcribeDelete(").count - 1, 1, "one call site")
        let dialog = try XCTUnwrap(page.range(of: ".confirmationDialog("), "the delete is confirmed")
        let call = try XCTUnwrap(page.range(of: "transcribeDelete("))
        XCTAssertGreaterThan(call.lowerBound, dialog.lowerBound, "the call sits inside the dialog")
        let glue = try source("OxSayDictation/TranscribeSource.swift")
        XCTAssertEqual(glue.components(separatedBy: "session.delete(").count - 1, 1)
        XCTAssertEqual(glue.components(separatedBy: "deleteTranscript").count - 1, 1, "the daemon's delete is called in one place: the ops")
        try XCTAssertTrue(body(glue, of: "func delete(").contains("session.delete(id:"))
    }

    /// The glue sends a pick through the session (which checks size and type) and reads the list on every refresh.
    func testThePickGoesThroughTheSessionAndTheListIsReadOnRefresh() throws {
        let glue = try source("OxSayDictation/TranscribeSource.swift")
        try XCTAssertTrue(body(glue, of: "func pick(").contains("session.submit("))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        try XCTAssertTrue(body(window, of: "func refresh() {").contains("transcribeSource.reload()"))
        XCTAssertTrue(window.contains("a.transcribePick = { [weak self] url in self?.transcribeSource.pick(url) }"))
    }

    /// Closing the window does not cancel an upload: the source's close handler never touches the session.
    /// Mutation: MainWindowSource.windowClosed, add `transcribeSource.cancel()` -> RED.
    func testClosingTheWindowDoesNotCancelAnUpload() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        try XCTAssertFalse(body(window, of: "func windowClosed() {").contains("transcribeSource"))
        let glue = try source("OxSayDictation/TranscribeSource.swift")
        XCTAssertFalse(glue.contains(".cancel()"), "nothing in the transcribe glue cancels a task")
    }

    /// The save panel writes through the session's file, on the main window's sheet.
    func testSaveGoesThroughTheHostPanel() throws {
        let glue = try source("OxSayDictation/TranscribeSource.swift")
        let save = try body(glue, of: "func save(")
        XCTAssertTrue(save.contains("session.file(id: id, format: format)"))
        XCTAssertTrue(save.contains("host.saveFile("))
        let app = try source("OxSayDictation/AppDelegate.swift")
        let host = try body(app, of: "func windowHost() -> MainWindowHost {")
        XCTAssertTrue(host.contains("saveFile:"))
    }

    func testTheSectionIsLive() {
        XCTAssertTrue(MainWindowSpec.liveSections.contains(.transcribe))
    }

    /// The panel's answer goes through `finishSave`, so a cancel never reaches the failure notice.
    /// Mutation: TranscribeSource.swift TranscriptSave.present, call `completion(false)` outside `finishSave` -> RED.
    func testTheSavePanelAnswersThroughFinishSave() throws {
        let glue = try source("OxSayDictation/TranscribeSource.swift")
        let panel = try XCTUnwrap(glue.range(of: "enum TranscriptSave"))
        let tail = String(glue[panel.lowerBound...])
        XCTAssertTrue(tail.contains("file.finishSave(confirmed: response == .OK, url: panel.url)"))
        XCTAssertEqual(tail.components(separatedBy: "completion(").count - 1, 1, "the panel reports through one call")
    }
}
