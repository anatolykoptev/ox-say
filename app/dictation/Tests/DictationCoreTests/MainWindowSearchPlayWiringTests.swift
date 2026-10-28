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

    /// Playback ends when the window closes, when a recording starts, when meetings are switched off and when another
    /// meeting is chosen. It does NOT end when the window is hidden, covered or minimised: someone listening while
    /// working in another app keeps hearing it (the clocks and the polling do stop).
    /// Mutation: MainWindowSource.windowClosed, delete `stopPlayback()` -> RED; or put `stopPlayback()` back in the
    /// hidden branch of visibilityChanged -> RED (and the same for recordingChanged, apply, selectMeeting).
    func testPlaybackStopsWhenTheWindowCloses_RecordingStarts_OrMeetingsGoOff_NotWhenHidden() throws {
        let w = try window()
        let hidden = try body(w, of: "func visibilityChanged(_ nowVisible: Bool) {")
        XCTAssertFalse(hidden.contains("stopPlayback"), "hidden: the audio goes on")
        XCTAssertTrue(hidden.contains("} else {\n            stopClocks()\n        }"), "hidden: the clocks stop")
        let closed = try body(w, of: "func windowClosed() {")
        XCTAssertTrue(closed.contains("stopPlayback()"), "closed: stop")
        XCTAssertTrue(closed.contains("cancelSearchWork()"), "closed: no search outlives the window")
        XCTAssertTrue(closed.contains("windowOpen = false"))
        // Every stop path goes through stopPlayback, and stopPlayback invalidates the probe on its way as well as
        // stopping the player: a probe that answers late must not start audio after a stop.
        let stopFn = flat(try body(w, of: "private func stopPlayback() {"))
        XCTAssertTrue(stopFn.contains("playRequests.invalidate() audio.stop()"), "stop invalidates the request in flight")
        XCTAssertEqual(w.components(separatedBy: "audio.stop()").count - 1, 1, "no other path stops the player without the invalidate")
        let cancel = try body(w, of: "private func cancelSearchWork() {")
        XCTAssertTrue(cancel.contains("searchTimer?.cancel()") && cancel.contains("searchRequest?.cancel()"))
        let opened = try body(w, of: "func windowOpened() {")
        XCTAssertTrue(opened.contains("windowOpen = true"))
        XCTAssertTrue(opened.contains("if model.data.search.phase == .searching { searchEvent(.retry) }"), "a cancelled search restarts, no stuck spinner")
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
        XCTAssertTrue(flat(detail).contains(".onDisappear { model.actions.stopPlayback()"), "leaving the meeting stops it")
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
        XCTAssertTrue(play.contains("let request = playRequests.begin()"))
        XCTAssertTrue(play.contains("guard playRequests.isCurrent(request, windowOpen: windowOpen) else { return }"), "a late probe is dropped; a hidden window is still open")
        XCTAssertFalse(play.contains("visible"), "hiding the window must not cancel the audio")
        XCTAssertTrue(play.contains("case .removed:") && play.contains("audioDeleted = true"), "a 410 is the audio-removed state")
    }

    /// No play affordance, and no click, when the audio is gone: the page asks the core's gate. The play button is the
    /// turn's header (speaker, time, glyph); the words are plain selectable text, so selecting never starts audio.
    /// Mutation: TranscriptTab, `if gate.showsAffordance {` (the button) -> `if true {` -> RED; or an `.onTapGesture` on
    /// the row -> RED.
    func testThePageDrawsNoPlayAffordanceWithoutAudio() throws {
        let t = try source("Sources/MainWindowUI/TranscriptTab.swift")
        XCTAssertTrue(t.contains("let gate = PlaybackGate.decide(audioDeleted: info.audioDeleted, recordingRunning: model.data.recordingElapsed != nil,"))
        XCTAssertEqual(t.components(separatedBy: "if gate.showsAffordance {").count - 1, 1, "one place decides")
        let f = flat(t)
        XCTAssertTrue(f.contains("if gate.showsAffordance { Button(action: play) { header(glyph: true) }"))
        XCTAssertTrue(f.contains("} else { header(glyph: false) }"))
        XCTAssertFalse(t.contains("onTapGesture"), "no tap on the row: a double click selects a word and must not play")
        XCTAssertTrue(f.contains(".accessibilityLabel(\"\\(L10nKey.playFromHere.text), \\(turn.speaker) \\(turn.time)\") .accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(t.contains("let playing = playingTurn(turns)"))
        XCTAssertTrue(t.contains("TurnClock.currentTurn(at: p.position, in: turns)"))
    }

    /// Find scrolls on the state's serial (not on `current`, which does not move for 0 → 0), ⌘F with the bar open keeps
    /// the match, the field is focused on the next run-loop turn, and the parsed turns are kept between ticks.
    /// Mutation: TranscriptTab, `.onChange(of: find.serial)` -> `.onChange(of: find.current)` -> RED; ⌘F calling
    /// `find.setQuery` while open -> RED; `findFocused = true` outside `DispatchQueue.main.async` -> RED.
    func testFindScrollsOnTheSerialAndKeepsItsMatch() throws {
        let t = try source("Sources/MainWindowUI/TranscriptTab.swift")
        let f = flat(t)
        XCTAssertTrue(f.contains(".onChange(of: find.serial) { _ in scrollToCurrentMatch(proxy) }"))
        XCTAssertFalse(t.contains("onChange(of: find.current)"))
        XCTAssertTrue(f.contains("if !findOpen { findOpen = true find.setQuery(query, turns: turns) } DispatchQueue.main.async { findFocused = true }"))
        XCTAssertTrue(f.contains("let (turns, order) = parsed.read(info.transcriptMD)"), "memoized per text")
        XCTAssertFalse(t.contains("TranscriptTurn.parse(") && t.contains("let turns = info.transcriptMD.map"), "no parse in body")
    }

    /// A hit's focus is for one visit: another selection clears it, so does leaving the meeting. A hit click itself sets it.
    /// Mutation: MainWindowModel.selectedMeeting didSet, delete `focus = nil` -> RED; MeetingDetailView.onDisappear,
    /// delete the focus clear -> RED.
    func testAHitsFocusDoesNotOutliveItsVisit() throws {
        let m = flat(try source("Sources/MainWindowUI/MainWindowModel.swift"))
        XCTAssertTrue(m.contains("didSet { if selectedMeeting != oldValue, !openingHit { focus = nil } }"))
        XCTAssertTrue(m.contains("openingHit = true selectedMeeting = meetingID openingHit = false focus = MeetingFocus("))
        let d = flat(try source("Sources/MainWindowUI/MeetingDetailView.swift"))
        XCTAssertTrue(d.contains("if model.focus?.meetingID == info.id { model.focus = nil }"))
    }

    /// "Nothing found" shows the skipped line.
    /// Mutation: SearchPane, delete `if let line = result.footnote()` in the .noResults case -> RED.
    func testNothingFoundStillSaysWhatWasSkipped() throws {
        let p = flat(try source("Sources/MainWindowUI/SearchPane.swift"))
        XCTAssertTrue(p.contains("case .noResults(let result):"))
        XCTAssertTrue(p.contains("if let line = result.footnote() { Text(line).font(.caption)"))
    }

    /// The end of an item that was replaced does not stop its successor.
    /// Mutation: MeetingAudioPlayer, delete `guard self?.player?.currentItem === item else { return }` in the end
    /// observer -> RED.
    func testTheEndObserverChecksItsItem() throws {
        let p = flat(try source("Sources/OxSayDictation/MeetingAudioPlayer.swift"))
        XCTAssertTrue(p.contains("guard self?.player?.currentItem === item else { return } self?.stop()"))
    }

    /// The player is its own thing: the plain URL (no header, no loader delegate), and no code path between it and the
    /// dictation's sound code (no media pause, no setting read), so playing never starts a dictation and the dictation
    /// code never pauses or stops the player. The system-volume duck of "Lower All Sound" does reach it, as it reaches
    /// every app: that is the user's own setting.
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
        XCTAssertTrue(s.contains("case .cancelInFlight: cancelSearchWork()"))
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

    /// A seek reports its position from the completion handler, not before the seek has landed.
    /// Mutation: MeetingAudioPlayer.seek, add `report()` back before the handler (or drop it from the handler) -> RED.
    func testASeekReportsWhenItHasLanded() throws {
        let player = try source("Sources/OxSayDictation/MeetingAudioPlayer.swift")
        let seek = try XCTUnwrap(body(player, of: "func seek(to seconds: TimeInterval) {"))
        let flatSeek = flat(seek)
        XCTAssertTrue(flatSeek.contains("toleranceAfter: .zero) { [weak self] _ in Task { @MainActor in guard let self, self.player === player else { return } self.report() } }"))
        XCTAssertEqual(seek.components(separatedBy: "report()").count - 1, 1, "reported once, from the handler")
    }
}
