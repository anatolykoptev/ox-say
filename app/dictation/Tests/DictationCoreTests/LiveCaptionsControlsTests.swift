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

    func testAClickAfterTheRecordingStoppedOpensTheMeetingsListAndNothingElse() {
        XCTAssertEqual(PlateClick.route(recordingID: nil), MainRoute(section: .meetings, meetingID: nil))
        XCTAssertEqual(PlateClick.route(recordingID: ""), MainRoute(section: .meetings, meetingID: nil))
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

    func testTheLivePollFollowsTheSelectedRecordingElseTheRecordingInTheList() {
        let other = MeetingInfo(id: "old", status: .done)
        XCTAssertEqual(LivePolling.target(visible: true, selected: recording, meetings: [other, recording]), "m1")
        XCTAssertEqual(LivePolling.target(visible: true, selected: other, meetings: [other, recording]), "m1",
                       "the row shows the last line even while another meeting is open")
        XCTAssertEqual(LivePolling.target(visible: true, selected: nil, meetings: [other, recording]), "m1")
        XCTAssertNil(LivePolling.target(visible: false, selected: recording, meetings: [recording]))
        XCTAssertNil(LivePolling.target(visible: true, selected: nil, meetings: [other]))
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
        XCTAssertTrue(try source("OxSayDictation/MeetingBadge.swift").contains("iconButton(\"text.bubble\", L10nKey.badgeOpenLive.text)"))
        XCTAssertTrue(try source("OxSayDictation/AppDelegate.swift").contains("openRoute: { [unowned self] route in self.mainWindow.show(route) }"))
    }

    func testTheSettingsSwitchShowsAFailedSaveOnItsOwnPage() throws {
        let page = try source("MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(page.contains("isOn: s.liveCaptions)"))
        XCTAssertTrue(page.contains("if let notice = model.data.notice { NoticeBar("), "Settings has no notice bar of its own")
    }

    func testTheRecordingRowReadsTheFeedOfTheMeetingItShows() throws {
        XCTAssertTrue(try source("MainWindowUI/MeetingsPage.swift").contains("MeetingRowCaption.line(info: m, feed: model.data.live[m.id])"))
        XCTAssertTrue(try source("OxSayDictation/MainWindowSource.swift").contains("LivePolling.target(visible: visible, selected: selected, meetings: model.data.meetings)"))
    }
}
