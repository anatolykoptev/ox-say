import Foundation
import XCTest
@testable import DictationCore

/// #611 / #612: the Settings switch for live captions, the recording plate's click, and the last caption in the
/// recording's row.
final class LiveCaptionsControlsTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "live-captions-\(UUID().uuidString)")! }
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    private func client(_ answer: String = "{}", status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func load(_ d: UserDefaults, daemon: MeetingDaemonSettings?) -> MeetingSettingsValues {
        MeetingSettingsModel.load(defaults: d, daemonRetention: daemon?.retention, daemonLiveCaptions: daemon?.liveCaptions,
                                  liveCaptionsDefault: daemon?.liveCaptionsDefault, notesWriter: .ready, fullName: "Alex Morgan", home: home)
    }

    // MARK: #611 settings

    func testTheDaemonsAnswerCarriesTheCaptionsSwitchAndItsDefault() throws {
        let s = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":false,"live_captions_default":true}"#.utf8)))
        XCTAssertEqual(s.liveCaptions, false)
        XCTAssertEqual(s.liveCaptionsDefault, true)
        let old = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":7}"#.utf8)))
        XCTAssertNil(old.liveCaptions, "a daemon that predates the field says nothing: not 'off'")
        XCTAssertNil(old.liveCaptionsDefault)
    }

    /// GET -> the switch shows the daemon's value -> the user flips it -> the PUT carries exactly the new value.
    /// Mutation: MeetingSettingsApplier.apply, `.liveCaptions(let on)` sends `!on` -> RED.
    func testTheSwitchRoundTripsFromTheGetToThePutBody() async throws {
        let d = suite()
        let daemon = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":true,"live_captions_default":false}"#.utf8)))
        let old = load(d, daemon: daemon)
        XCTAssertTrue(old.liveCaptions)
        XCTAssertTrue(old.liveCaptionsVerified)
        XCTAssertEqual(old.liveCaptionsDefault, false)
        var new = old
        new.liveCaptions = false
        let changes = MeetingSettingsModel.changes(from: old, to: new)
        XCTAssertEqual(changes, [.liveCaptions(false)])
        XCTAssertFalse(changes[0].needsRefresh)
        var seen: URLRequest?
        let failure = await MeetingSettingsApplier(defaults: d, client: client(record: { seen = $0 })).apply(changes[0])
        XCTAssertNil(failure)
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/settings")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual(body as? [String: Bool], ["live_captions": false], "only this field: the retention is not touched")
        XCTAssertFalse(MeetingSettings.liveCaptionsCopy(d) ?? true)
    }

    /// A PUT the daemon refused says why and stores nothing, so the page's reload shows the saved value again.
    /// Mutation: MeetingSettingsApplier.apply, store the copy before the request -> RED.
    func testAFailedPutIsSaidAndTheToggleReturnsToTheSavedValue() async throws {
        let d = suite()
        let daemon = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":true}"#.utf8)))
        _ = await MeetingSettingsApplier(defaults: d, client: client()).apply(.liveCaptions(true))
        let failure = await MeetingSettingsApplier(defaults: d, client: client(status: 500)).apply(.liveCaptions(false))
        XCTAssertNotNil(failure)
        XCTAssertEqual(MeetingSettings.liveCaptionsCopy(d), true, "nothing was stored")
        XCTAssertTrue(load(d, daemon: daemon).liveCaptions, "the daemon still says on")
        XCTAssertTrue(load(d, daemon: nil).liveCaptions, "daemon unreachable: the last saved value")
        let down = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await MeetingSettingsApplier(defaults: d, client: down).apply(.liveCaptions(false), text: { $0.rawValue })
        XCTAssertEqual(unreachable, "meeting.error.daemon_down")
        XCTAssertEqual(MeetingSettings.liveCaptionsCopy(d), true)
    }

    func testAnUncheckedSwitchIsMarkedAndNeverInventedAsOn() {
        let v = load(suite(), daemon: nil)
        XCTAssertFalse(v.liveCaptionsVerified)
        XCTAssertFalse(v.liveCaptions)
        XCTAssertNil(v.liveCaptionsDefault)
    }

    // MARK: #612 plate click

    /// Mutation: PlateClick.route, `meetingID: recordingID` -> `meetingID: nil` (the list instead of the live page) -> RED.
    func testAClickOnThePlateOpensTheLivePageOfTheMeetingBeingRecorded() {
        XCTAssertEqual(PlateClick.route(recordingID: "20261115-100000-abcdef"),
                       MainRoute(section: .meetings, meetingID: "20261115-100000-abcdef"))
    }

    func testAClickAfterTheRecordingStoppedOpensTheListWithNoMeetingChosen() {
        for none in [nil, ""] {
            let route = PlateClick.route(recordingID: none)
            XCTAssertEqual(route.section, .meetings)
            XCTAssertNil(route.selection(current: "20261115-090000-old"), "the list, not the meeting that happened to be open")
            XCTAssertEqual(route.resolved().selection(current: "x"), nil, "resolving keeps the instruction")
            XCTAssertNil(route.pruned(knownMeetingIDs: ["a"]).selection(current: "x"))
        }
        // nil keeps its old meaning for every other caller: the open meeting stays.
        XCTAssertEqual(MainRoute(section: .meetings).selection(current: "open"), "open")
        XCTAssertEqual(MainRoute(section: .meetings, meetingID: "m2").selection(current: "open"), "m2")
    }

    // MARK: #612 row caption

    private func caption(_ seq: Int, _ text: String) -> LiveCaption { LiveCaption(seq: seq, channel: .them, start: 0, end: 1, text: text) }

    private func feed(_ texts: [String], enabled: Bool = true) -> LiveFeed {
        var f = LiveFeed()
        f.apply(LiveAnswer(captions: texts.enumerated().map { caption($0.offset + 1, $0.element) }, next: texts.count,
                           state: LiveCaptionState(enabled: enabled)))
        return f
    }

    private let recording = MeetingInfo(id: "m1", status: .recording)

    /// Mutation: MeetingRowCaption.line, `.last` -> `.first` -> RED.
    func testTheRowShowsTheLastCaptionLine() {
        XCTAssertEqual(MeetingRowCaption.line(info: recording, feed: feed(["first", "second", "third"])), "third")
    }

    func testTheRowShowsNothingWithoutALineOrWithCaptionsOffOrWhenNotRecording() {
        XCTAssertNil(MeetingRowCaption.line(info: recording, feed: nil))
        XCTAssertNil(MeetingRowCaption.line(info: recording, feed: feed([])))
        XCTAssertNil(MeetingRowCaption.line(info: recording, feed: feed(["held back"], enabled: false)))
        XCTAssertNil(MeetingRowCaption.line(info: MeetingInfo(id: "m1", status: .done), feed: feed(["stale"])))
    }

    func testALongOrMultiLineCaptionIsOneBoundedLine() throws {
        let one = try XCTUnwrap(MeetingRowCaption.line(info: recording, feed: feed(["line one\n  line two\tend"])))
        XCTAssertEqual(one, "line one line two end")
        let long = String(repeating: "word ", count: 200)
        let cut = try XCTUnwrap(MeetingRowCaption.line(info: recording, feed: feed([long])))
        XCTAssertLessThanOrEqual(cut.count, MeetingRowCaption.maxCharacters)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    // MARK: #612 polling target

    private let old = MeetingInfo(id: "old", status: .done)

    func testTheLivePollFollowsTheSelectedRecordingElseTheRecordingThePlateShows() {
        let t = LiveTargeting()
        let other = MeetingInfo(id: "m2", status: .recording)
        XCTAssertEqual(t.target(visible: true, selected: recording, meetings: [old, recording], recordingID: "m1"), "m1")
        XCTAssertEqual(t.target(visible: true, selected: old, meetings: [old, recording], recordingID: "m1"), "m1",
                       "the row shows the last line even while another meeting is open")
        XCTAssertNil(t.target(visible: false, selected: recording, meetings: [recording], recordingID: "m1"))
        XCTAssertNil(t.target(visible: true, selected: nil, meetings: [old], recordingID: "m1"))
        XCTAssertNil(t.target(visible: true, selected: nil, meetings: [recording], recordingID: nil), "the app records nothing: no fallback")
        _ = other
    }

    /// With two rows that say "recording" the fallback is the one the plate shows, not the first in the list.
    /// Mutation: LiveTargeting.target, `$0.id == recordingID && ` removed (first recording row) -> RED.
    func testTheFallbackFollowsThePlatesRecordingNotTheFirstRecordingRow() {
        let stale = MeetingInfo(id: "stale", status: .recording)
        let live = MeetingInfo(id: "live", status: .recording)
        XCTAssertEqual(LiveTargeting().target(visible: true, selected: nil, meetings: [stale, live], recordingID: "live"), "live")
    }

    /// `/live` says "not recording", the list read behind it fails, the old row keeps saying "recording": every
    /// reschedule asks for a target again. It must ask once, not once per pass.
    /// Mutation: LiveTargeting.reportedStopped, `stopped.insert(id)` removed -> RED (a request on every pass).
    func testAStoppedRecordingIsNotPolledAgainWhenTheListReadFails() {
        var t = LiveTargeting()
        var liveRequests = 0
        let rows = [MeetingInfo(id: "m1", status: .recording)] // the list never refreshes: its read failed
        for _ in 0..<50 { // 50 reschedules in a window
            guard let id = t.target(visible: true, selected: rows[0], meetings: rows, recordingID: "m1") else { continue }
            liveRequests += 1
            t.reportedStopped(id) // the daemon answered recording: false
        }
        XCTAssertEqual(liveRequests, 1)
    }

    // MARK: #611 saves

    /// Off then on, quickly; the first PUT is still running when the second intent arrives. The daemon must end on the last
    /// intent and the page must show the value the daemon took last.
    /// Mutation: LiveCaptionsSaveQueue.submit, `latest = on` removed (the newer intent is dropped) -> RED.
    @MainActor func testTwoQuickTogglesEndWithTheDaemonAndThePageOnTheLastIntent() async {
        var daemon = true
        var sent: [Bool] = []
        var gate: CheckedContinuation<Void, Never>?
        var outcomes: [LiveCaptionsSaveQueue.Outcome] = []
        let queue = LiveCaptionsSaveQueue(send: { on in
            sent.append(on)
            if sent.count == 1 { await withCheckedContinuation { gate = $0 } } // the first PUT is slow
            daemon = on
            return nil
        }, finished: { outcomes.append($0) })
        queue.submit(false)
        for _ in 0..<100 where gate == nil { await Task.yield() }
        queue.submit(true)
        XCTAssertTrue(queue.busy)
        gate?.resume()
        await queue.idle()
        XCTAssertEqual(sent, [false, true], "one at a time, in the order chosen")
        XCTAssertTrue(daemon)
        XCTAssertEqual(outcomes, [.saved(true)])
        XCTAssertFalse(queue.busy)
    }

    @MainActor func testAFailureOfTheLastSendIsTheOutcomeAndAnEarlierOneIsNot() async {
        var calls = 0
        var outcomes: [LiveCaptionsSaveQueue.Outcome] = []
        let queue = LiveCaptionsSaveQueue(send: { _ in calls += 1; return calls == 1 ? "refused" : nil }, finished: { outcomes.append($0) })
        queue.submit(false)
        queue.submit(true) // arrives before the first send ran
        await queue.idle()
        XCTAssertEqual(outcomes.count, 1)
        let failing = LiveCaptionsSaveQueue(send: { _ in "refused" }, finished: { outcomes.append($0) })
        failing.submit(false)
        await failing.idle()
        XCTAssertEqual(outcomes.last, .failed("refused"))
    }

    /// A settings read that began before an edit, or while one ran, is older than the edit: the switch keeps the edit.
    @MainActor func testAReadOlderThanAnEditIsIgnoredForTheSwitch() async throws {
        let queue = LiveCaptionsSaveQueue(send: { _ in nil }, finished: { _ in })
        let before = queue.beginRead()
        XCTAssertFalse(queue.isStale(before), "no edit: the read stands")
        queue.submit(false)
        XCTAssertTrue(queue.isStale(before), "an edit began after the read started")
        let during = queue.beginRead()
        XCTAssertTrue(queue.isStale(during), "a save is running")
        await queue.idle()
        XCTAssertTrue(queue.isStale(during), "the read started while a save ran: it may carry the old value")
        XCTAssertTrue(queue.isStale(before))
        XCTAssertFalse(queue.isStale(queue.beginRead()), "a read that began after the save is current")

        let d = suite()
        let daemon = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":true}"#.utf8)))
        var current = load(d, daemon: daemon)
        current.liveCaptions = false // the edit
        let loadedOld = load(d, daemon: daemon) // the old GET says on
        XCTAssertTrue(MeetingSettingsModel.keepingPendingEdit(loadedOld, current: current).liveCaptions == false)
    }

    func testASuccessfulReadRefreshesTheStoredCopy() throws {
        let d = suite()
        MeetingSettings.setLiveCaptionsCopy(false, d)
        let daemon = try XCTUnwrap(MeetingDaemonSettings.decode(Data(#"{"retention_days":30,"live_captions":true}"#.utf8)))
        _ = load(d, daemon: daemon)
        XCTAssertEqual(MeetingSettings.liveCaptionsCopy(d), true)
        _ = load(d, daemon: nil)
        XCTAssertEqual(MeetingSettings.liveCaptionsCopy(d), true, "an unreachable daemon changes nothing")
        XCTAssertTrue(load(d, daemon: nil).liveCaptions, "so the fallback is the last value the daemon said")
    }

    // MARK: app glue (pinned as source text, like the other wiring tests: the AppKit side cannot run here)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + path), encoding: .utf8)
    }

    func testThePlateButtonReachesTheWindowThroughPlateClick() throws {
        let controller = try source("OxSayDictation/MeetingController.swift")
        XCTAssertTrue(controller.contains("badge.onOpenLive = { [weak self] in self?.openLive() }"))
        XCTAssertTrue(controller.contains("host.openRoute(PlateClick.route(recordingID: current?.info.id))"))
        XCTAssertTrue(try source("OxSayDictation/MeetingBadge.swift").contains(
            "iconButton(\"text.bubble\", L10nKey.badgeOpenLive.text) { [weak self] in self?.onOpenLive?() }"), "the button's action calls onOpenLive")
        XCTAssertTrue(try source("OxSayDictation/AppDelegate.swift").contains("openRoute: { [unowned self] route in self.mainWindow.show(route) }"))
    }

    func testTheSettingsSwitchShowsAFailedSaveOnItsOwnPage() throws {
        let page = try source("MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(page.contains("if let notice = model.data.notice { NoticeBar("), "Settings has no notice bar of its own")
    }

    func testTheRecordingRowReadsTheFeedOfTheMeetingItShows() throws {
        XCTAssertTrue(try source("MainWindowUI/MeetingsPage.swift").contains("MeetingRowCaption.line(info: m, feed: model.data.live[m.id])"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("recordingID: host.meetings()?.recordingID"), "the fallback follows the plate's recording")
        XCTAssertTrue(window.contains("liveTargeting.reportedStopped(id)"))
        XCTAssertTrue(window.contains("model.selectedMeeting = route.selection(current: model.selectedMeeting)"))
        XCTAssertTrue(window.contains("liveSaves.submit(on)"), "the switch is saved through the queue")
    }
}
