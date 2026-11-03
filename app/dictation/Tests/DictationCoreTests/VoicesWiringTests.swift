import Foundation
import XCTest
@testable import DictationCore

/// Source pins for the Voices page's glue (the shim compiles DictationCore only, so the AppKit/SwiftUI files are read as
/// text, without comments). What each decision DOES is tested in VoiceLibrarySessionTests; these prove the glue calls
/// the decision from the place that counts and carries its result to the window.
final class VoicesWiringTests: XCTestCase {
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

    /// Delete goes through the session (which cleans the picks), and nowhere else touches the daemon's delete or the
    /// pick keys. Mutation: VoiceSource.delete, `session.delete(id: id)` -> `client.deleteVoice` style bypass -> RED.
    func testTheWindowDeletesOnlyThroughTheSession() throws {
        let text = try source("OxSayDictation/VoiceSource.swift")
        try XCTAssertTrue(body(text, of: "func delete(").contains("session.delete(id: id)"))
        XCTAssertEqual(text.components(separatedBy: "deleteVoice(").count - 1, 1, "the daemon's delete is called in one place: the ops")
        XCTAssertEqual(text.components(separatedBy: "removeObject(").count - 1, 1, "the picks are written in one place")
        try XCTAssertTrue(body(text, of: "func rename(").contains("session.rename(id: id, label: label)"))
        try XCTAssertTrue(body(text, of: "func preview(").contains("session.preview("))
    }

    /// The session's result reaches the window: the list, how the read went, the voice that plays, the picks.
    /// Mutation: VoiceSource.sync, delete `values.load = session.load` -> RED.
    func testTheSessionIsCopiedIntoTheWindowValues() throws {
        let sync = try body(try source("OxSayDictation/VoiceSource.swift"), of: "func sync(")
        for line in ["values.entries = session.entries", "values.load = session.load", "values.playingID = playing ?? session.playingID",
                     "values.russianVoice = session.picks.russian", "values.englishVoice = session.picks.english",
                     "changed(values.voices)"] {
            XCTAssertTrue(sync.contains(line), line)
        }
    }

    /// The window's actions reach VoiceSource, a refresh reads the library, a close stops a playing sample.
    /// Mutation: MainWindowSource.actions, delete the `a.deleteVoice` line -> RED.
    func testTheActionsAndTheRefreshReachTheVoiceSource() throws {
        let text = try source("OxSayDictation/MainWindowSource.swift")
        let actions = try body(text, of: "private func actions() -> MainWindowActions {")
        for name in ["reloadVoices", "previewVoice", "stopPreview", "renameVoice", "deleteVoice"] {
            XCTAssertTrue(actions.contains("a.\(name) = "), name)
        }
        XCTAssertTrue(actions.contains("voiceSource.delete(id)"))
        try XCTAssertTrue(body(text, of: "func refresh() {").contains("voiceSource.reload()"))
        try XCTAssertTrue(body(text, of: "func windowClosed() {").contains("voiceSource.stopPreview()"))
    }

    /// The menu's voice list and checkmarks follow the library: the host closure sets the list and rebuilds the menu.
    /// Mutation: AppDelegate.windowHost, delete `self.rebuildVoiceMenus()` in voicesChanged -> RED.
    func testTheMenuFollowsTheLibrary() throws {
        let host = try body(try source("OxSayDictation/AppDelegate.swift"), of: "func windowHost() -> MainWindowHost {")
        let changed = try XCTUnwrap(host.range(of: "voicesChanged:"))
        let tail = String(host[changed.lowerBound...].prefix(200))
        XCTAssertTrue(tail.contains("self.knownVoices = voices"))
        XCTAssertTrue(tail.contains("self.rebuildVoiceMenus()"))
        XCTAssertTrue(host.contains("speech: speechClient"))
    }

    /// The page offers no add menu or any other control without an action in this task, and draws a sample's play
    /// button only through IconButton. Rename and delete are the only mutations it can start.
    func testThePageHasNoDeadControls() throws {
        let page = try source("MainWindowUI/VoicesPage.swift")
        XCTAssertFalse(page.contains("addEnabled"))
        XCTAssertFalse(page.contains("L10nKey.voicesAdd"))
        XCTAssertTrue(page.contains("model.actions.renameVoice(entry.id, draft)"))
        XCTAssertTrue(page.contains("model.actions.deleteVoice(entry.id)"))
        XCTAssertTrue(page.contains("model.actions.previewVoice(entry.id)"))
        XCTAssertTrue(page.contains("model.actions.stopPreview()"))
        XCTAssertTrue(page.contains("model.actions.reloadVoices()"))
    }

    /// A preview never changes the system volume: the glue uses the app's AudioPlayer (AVAudioPlayer, per-player
    /// volume) and no system-volume type.
    func testThePreviewTouchesNoSystemVolume() throws {
        let text = try source("OxSayDictation/VoiceSource.swift")
        for forbidden in ["CoreAudioSystemVolume", "SystemVolume", "VolumeDuck", ".volume ="] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }
}
