import Foundation
import XCTest
@testable import DictationCore

/// The shim compiles DictationCore only, so the AppKit and SwiftUI glue of search, find and play is read as text,
/// WITHOUT its comments, and pinned to the expression that matters. What each decision DOES is tested in DictationCore
/// (MeetingSearchTests, MeetingPlaybackTests, TranscriptFindTests); these prove the glue asks the core from the place
/// that counts. Each test names the mutation that must turn it red.
final class MainWindowSearchPlayWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// The text with every run of whitespace as one space: a pin must not depend on the line breaks the glue happens to have.
    private func flat(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }

    private func window() throws -> String { try source("Sources/OxSayDictation/MainWindowSource.swift") }

    /// Playback ends when the window closes or hides, when a recording starts, when meetings are switched off and when
    /// another meeting is chosen.
    /// Mutation: MainWindowSource.visibilityChanged, delete `stopPlayback()` in the hidden branch -> RED (and the same
    /// for windowClosed, recordingChanged, apply, selectMeeting).
    func testPlaybackStopsWhenTheWindowHidesCloses_RecordingStarts_OrMeetingsGoOff() throws {
        let w = try window()
        let hidden = try body(w, of: "func visibilityChanged(_ nowVisible: Bool) {")
        XCTAssertTrue(hidden.contains("} else {\n            stopPlayback()\n            stopClocks()"), "hidden: stop")
        let closed = try body(w, of: "func windowClosed() {")
        XCTAssertTrue(closed.contains("stopPlayback()"), "closed: stop")
        let rec = try body(w, of: "func recordingChanged() {")
        let stop = try XCTUnwrap(rec.range(of: "if host.meetings()?.recordingElapsed != nil { stopPlayback() }"), "a recording starts: stop")
        let visible = try XCTUnwrap(rec.range(of: "guard visible else { return }"))
        XCTAssertTrue(stop.lowerBound < visible.lowerBound, "even when the window is hidden")
        let apply = try body(w, of: "private func apply(_ change: MeetingSettingsModel.Change) {")
        XCTAssertTrue(apply.contains("if case .enabled(false) = change { stopPlayback() }"))
        let select = try body(w, of: "private func selectMeeting(_ id: String) {")
        XCTAssertTrue(select.contains("if audio.activeMeeting != id { stopPlayback() }"))
        XCTAssertTrue(w.contains("a.selectMeeting = { [weak self] id in self?.selectMeeting(id) }"))
        XCTAssertTrue(w.contains("a.stopPlayback = { [weak self] in self?.stopPlayback() }"))
        let detail = try source("Sources/MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(detail.contains(".onDisappear { model.actions.stopPlayback() }"), "leaving the meeting stops it")
    }

    /// A click is decided from the live recording state, through the core's gate and plan, and starts at the line.
    /// Mutation: MainWindowSource.playTurn, `recordingRunning: host.meetings()?.recordingElapsed != nil` -> `false` -> RED;
    /// or `audio.play(... from: start)` -> `from: 0` -> RED.
    func testAClickPlaysThroughTheGateFromTheLine() throws {
        let play = flat(try body(try window(), of: "private func playTurn(_ id: String, _ turn: TranscriptTurn) {"))
        XCTAssertTrue(play.contains("recordingRunning: host.meetings()?.recordingElapsed != nil"))
        XCTAssertTrue(play.contains("switch PlaybackPlan.start(turn: turn, gate: gate) {"))
        XCTAssertTrue(play.contains("case .refused(.recording): stopPlayback() model.data.notice = L10nKey.playBlockedRecording.text"), "the reason is said")
        XCTAssertTrue(play.contains("audio.play(url: host.client.meetingAudioURL(id: id), meetingID: id, from: start)"))
        XCTAssertTrue(play.contains("guard host.meetings()?.recordingElapsed == nil else {"), "a recording that began during the probe still refuses")
        XCTAssertTrue(play.contains("case .removed:") && play.contains("audioDeleted = true"), "a 410 is the audio-removed state")
    }

    /// No play affordance, and no click, when the audio is gone: the page asks the core's gate for both.
    /// Mutation: TranscriptTab, `if gate.showsAffordance {` (the glyph) -> `if true {` -> RED.
    func testThePageDrawsNoPlayAffordanceWithoutAudio() throws {
        let t = try source("Sources/MainWindowUI/TranscriptTab.swift")
        XCTAssertTrue(t.contains("let gate = PlaybackGate.decide(audioDeleted: info.audioDeleted, recordingRunning: model.data.recordingElapsed != nil,"))
        XCTAssertEqual(t.components(separatedBy: "if gate.showsAffordance {").count - 1, 2, "the glyph and the click")
        XCTAssertTrue(t.contains("row.contentShape(Rectangle()).onTapGesture(perform: play)"))
        XCTAssertTrue(t.contains("let playing = playingTurn(turns)"))
        XCTAssertTrue(t.contains("TurnClock.currentTurn(at: p.position, in: turns)"))
    }

    /// The player is its own thing: the plain URL (no header, no loader delegate), and nothing of the dictation sound
    /// code, so a dictation neither ducks nor pauses it and playing never starts one.
    /// Mutation: MeetingAudioPlayer, an `AVURLAssetHTTPHeaderFieldsKey` option, or any reference to the duck coordinator -> RED.
    func testThePlayerIsApartFromDictationAndCarriesNoSecret() throws {
        let p = try source("Sources/OxSayDictation/MeetingAudioPlayer.swift")
        XCTAssertTrue(p.contains("AVPlayerItem(asset: AVURLAsset(url: url))"))
        for word in ["AVURLAssetHTTPHeaderFieldsKey", "AVAssetResourceLoader", "Authorization", "Duck", "SoundWhileDictating",
                     "MediaPause", "DictationController", "MPNowPlayingInfoCenter", "print(", "NSLog", "os_log", "Logger"] {
            XCTAssertFalse(p.contains(word), "\(word) must not appear in the player")
        }
        let build = try source("build.sh")
        XCTAssertTrue(build.contains("<key>NSAllowsLocalNetworking</key><true/>"), "ATS lets AVPlayer reach http://127.0.0.1")
        for core in ["Sources/DictationCore/VolumeDuck.swift", "Sources/DictationCore/SoundWhileDictating.swift",
                     "Sources/DictationCore/SoundWhileDictatingWiring.swift", "Sources/DictationCore/MediaPauseCoordinator.swift"] {
            let text = try source(core)
            XCTAssertFalse(text.contains("MeetingAudioPlayer"), "\(core) knows nothing of the meeting player")
        }
    }

    /// Search: typing goes through the core's state machine; the effects cancel the stale request and drop an answer
    /// that arrives after the cancel.
    /// Mutation: MainWindowSource.searchEvent, `searchRequest?.cancel()` in .cancelInFlight deleted -> RED; or the
    /// `guard !Task.isCancelled` before `.answered` deleted -> RED.
    func testSearchRunsTheCoreAndCancelsTheStaleRequest() throws {
        let s = flat(try body(try window(), of: "private func searchEvent(_ event: MeetingSearchEvent) {"))
        XCTAssertTrue(s.contains("let effects = MeetingSearch.reduce(&state, event)"))
        XCTAssertTrue(s.contains("case .cancelInFlight: searchTimer?.cancel() searchRequest?.cancel()"))
        XCTAssertTrue(s.contains("let answer = await client.searchMeetings(query: query)"))
        XCTAssertTrue(s.contains("guard !Task.isCancelled else { return } self?.searchEvent(.answered(generation: generation, answer))"))
        let w = try window()
        XCTAssertTrue(w.contains("a.searchTyped = { [weak self] text in self?.searchEvent(.typed(text)) }"))
    }

    /// A snippet is shown through the core's link-free renderer; a transcript turn is shown verbatim (no markup read).
    /// Mutation: SearchPane.HitRow, `SearchSnippet.attributed(hit.snippet, query: query)` -> `try! AttributedString(markdown: hit.snippet)` -> RED.
    func testSnippetsGoThroughTheLinkFreeRenderer() throws {
        let pane = try source("Sources/MainWindowUI/SearchPane.swift")
        XCTAssertTrue(pane.contains("SearchSnippet.attributed(hit.snippet, query: query)"))
        XCTAssertFalse(pane.contains("AttributedString(markdown"))
        let t = try source("Sources/MainWindowUI/TranscriptTab.swift")
        XCTAssertFalse(t.contains("AttributedString(markdown"))
        XCTAssertTrue(t.contains("TextHighlight.attributed(turn.text"))
        XCTAssertTrue(pane.contains("model.openHit(m.id, hit)"))
        let model = try source("Sources/MainWindowUI/MainWindowModel.swift")
        XCTAssertTrue(model.contains("focus = MeetingFocus(meetingID: meetingID, destination: hit.destination, serial: focusSerial)"))
        let detail = try source("Sources/MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(detail.contains("_tab = State(initialValue: MeetingTab(focus.destination))"))
    }

    /// #270: the name field saves what was typed when the page goes away; the rename draft does not turn an auto title
    /// into the user's own.
    /// Mutation: SettingsPage.NameField, delete `.onDisappear { commit(draft) }` -> RED; MeetingDetailView.saveTitle,
    /// `MeetingRowModel.renamedTitle(` -> a plain trim -> RED.
    func testNameFieldCommitsOnDisappearAndRenameKeepsTheAutoTitle() throws {
        let settings = try source("Sources/MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(settings.contains(".onDisappear { commit(draft) }"))
        let d = try source("Sources/MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(d.contains("guard let title = MeetingRowModel.renamedTitle(draft: draftTitle, shown: MeetingRowModel.displayTitle(of: info)) else { return }"))
    }
}
