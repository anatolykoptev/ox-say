import Foundation
import XCTest
@testable import DictationCore

/// The shim compiles DictationCore only, so the window's glue for live captions is read as text, WITHOUT its comments,
/// and pinned to the expressions that matter: what the decisions DO is tested in MeetingLiveTests; these prove the
/// window calls them from the place that counts, so the view cannot sit on "Listening…" while nothing polls.
final class MeetingLiveWiringTests: XCTestCase {
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

    /// A refresh pass and a route change reach the poll, and it asks `LivePolling` before it runs.
    /// Mutation: MainWindowSource.schedulePolling, delete `syncLive()` -> RED; syncLive, drop `LivePolling.needed(...)`
    /// from the guard -> RED (a finished meeting is polled, or none is).
    func testThePollIsStartedFromTheWindowsPollingAndAsksLivePolling() throws {
        let text = try source("OxSayDictation/MainWindowSource.swift")
        let schedule = try body(text, of: "private func schedulePolling() {")
        XCTAssertTrue(schedule.contains("syncLive()"))
        let sync = try body(text, of: "private func syncLive() {")
        XCTAssertTrue(sync.contains("model.section == .meetings,"))
        XCTAssertTrue(sync.contains("liveTargeting.target(visible: visible, selected: selected, meetings: model.data.meetings,"))
        XCTAssertTrue(sync.contains("stopLive()"))
        let stop = try body(text, of: "private func stopClocks() {")
        XCTAssertTrue(stop.contains("stopLive()"), "a hidden or closed window polls nothing")
    }

    /// One poll asks from the cursor the feed holds, applies the answer to the feed and stores it where the view reads.
    /// Mutation: MainWindowSource.readLive, `after: feed.cursor` -> `after: 0` -> RED (every poll repeats the whole call);
    /// delete `model.data.live[id] = feed` -> RED (the view never changes).
    func testAPollAsksFromTheCursorAndStoresTheFeed() throws {
        let read = try body(try source("OxSayDictation/MainWindowSource.swift"), of: "private func readLive(_ id: String) async -> Bool {")
        XCTAssertTrue(read.contains("host.client.liveCaptions(id: id, after: feed.cursor)"))
        XCTAssertTrue(read.contains("feed.apply(answer)"))
        XCTAssertTrue(read.contains("model.data.live[id] = feed"))
        XCTAssertTrue(read.contains("if !answer.state.recording {"), "the loop ends with the recording")
        XCTAssertTrue(read.contains("feed.pollFailed()"), "a failed poll is counted, not swallowed")
        let sync = try body(try source("OxSayDictation/MainWindowSource.swift"), of: "private func syncLive() {")
        XCTAssertTrue(sync.contains("LivePolling.delay(failures:"), "the poll slows down after repeated failures")
    }

    /// A recording meeting shows the captions in place of the tabs, fed from the window's own data.
    /// Mutation: MeetingDetailView.body, delete the `if recording {` branch -> RED (the tabs show for a recording);
    /// `model.data.live[info.id]` -> `LiveFeed()` -> RED (the view is never fed).
    func testARecordingMeetingShowsTheLiveView() throws {
        let view = try source("MainWindowUI/MeetingDetailView.swift")
        XCTAssertTrue(view.contains("private var recording: Bool { info.status == .recording }"))
        let main = try body(view, of: "var body: some View {")
        XCTAssertTrue(main.contains("if recording {"))
        XCTAssertTrue(main.contains("LiveCaptionsView(feed: model.data.live[info.id] ?? LiveFeed(), ownerName: info.ownerLabel ?? \"\")"))
        let captions = try source("MainWindowUI/LiveCaptionsView.swift")
        XCTAssertTrue(captions.contains("LiveNotice.key(for: feed)"))
    }
}
