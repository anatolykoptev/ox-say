import XCTest
@testable import DictationCore

/// Source pins for the cleanup bar (the shim compiles DictationCore only; the AppKit/SwiftUI files are read as text, without
/// comments). The decisions are tested in CleanSessionTests and CleanActionStateTests; these pin where the bar lives.
final class CleanWiringTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    /// Voice cleanup is never offered on meetings or dictation (owner rule): the bar is drawn by the file page and by no other
    /// page of the window.
    /// Mutation: add `CleanBar(model: model)` to MeetingsPage.swift or DictationPage.swift -> RED.
    func testCleanActionIsOnlyOnTheFilePage() throws {
        let dir = root.appendingPathComponent("Sources/MainWindowUI")
        var users: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".swift") {
            let text = MeetingWiringTests.stripComments(try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            if text.contains("CleanBar(") || text.contains("actions.cleanPick") { users.append(file) }
        }
        XCTAssertEqual(users, ["CleanBar.swift", "TranscribePage.swift"].sorted())
        let page = try source("MainWindowUI/TranscribePage.swift")
        XCTAssertTrue(page.contains("CleanBar(model: model)"))
        XCTAssertFalse(page.contains("actions.cleanPick"), "the page only draws the bar")
    }

    /// No code of the meeting or dictation features reaches the cleanup client.
    /// Mutation: call `cleanVoice(` from MeetingWindowService.swift -> RED.
    func testNoMeetingOrDictationCodeCallsTheCleanup() throws {
        let dir = root.appendingPathComponent("Sources")
        var callers: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: dir.path))
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let text = MeetingWiringTests.stripComments(try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8))
            if text.contains("cleanVoice(") { callers.append(path) }
        }
        XCTAssertEqual(callers.sorted(), ["DictationCore/CleanClient.swift", "OxSayDictation/CleanSource.swift"])
    }

    /// A running cleanup holds a pending relaunch, like an upload.
    /// Mutation: MainWindowSource `|| cleanSource.working` removed -> RED.
    func testACleanupHoldsTheHandshake() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("transcribeSource.transcribing || cleanSource.working"))
    }

    /// Only the person's own save panel names the output, and a refused replace goes through the panel's answer.
    func testTheOutputIsChosenInTheSavePanel() throws {
        let glue = try source("OxSayDictation/CleanSource.swift")
        XCTAssertTrue(glue.contains("host.chooseCleanOutput("))
        XCTAssertTrue(glue.contains("overwrite: FileManager.default.fileExists(atPath: output.path)"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("chooseCleanOutput:"))
    }

    /// Leaving the file page stops the comparison: no sound plays on Встречи or Диктовка with no control for it.
    /// Mutation: MainWindowSource.swift, delete `if section != .transcribe { self?.cleanSource.stopPlayback() }` -> RED.
    func testLeavingTheFilePageStopsTheComparison() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let sink = try XCTUnwrap(window.range(of: "routeSaver = Publishers.CombineLatest3("))
        let body = String(window[sink.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("if section != .transcribe { self?.cleanSource.stopPlayback() }"), body)
    }

    /// Closing the window stops the sound, never the job.
    func testClosingTheWindowStopsTheSoundNotTheJob() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        let start = try XCTUnwrap(window.range(of: "func windowClosed() {"))
        let body = String(window[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("cleanSource.stopPlayback()"))
        XCTAssertFalse(body.contains("cleanSource.cancel()"))
    }
}
