import Foundation
import XCTest
@testable import DictationCore

final class MeetingMenuTests: XCTestCase {
    private func rows(_ s: MeetingMenuState) -> [MenuRow] {
        MeetingMenu.rows(s, text: { $0 == .menuMeetingStop ? "Stop (%@)" : $0.rawValue })
    }
    private func state(recording: TimeInterval? = nil, notes: NotesStatus = NotesStatus(available: true), supported: Bool = true) -> MeetingMenuState {
        MeetingMenuState(supported: supported, recordingElapsed: recording, notes: notes, autoStart: true, retention: .month)
    }
    private func actions(_ rows: [MenuRow]) -> [MenuAction] {
        rows.compactMap { if case .item(_, _, _, let a) = $0 { return a } else { return nil } }
    }

    func testIdleOffersRecordAndRecordingOffersStop() {
        XCTAssertTrue(actions(rows(state())).contains(.startMeeting))
        XCTAssertFalse(actions(rows(state())).contains(.stopMeeting))
        XCTAssertTrue(actions(rows(state(recording: 65))).contains(.stopMeeting))
        XCTAssertFalse(actions(rows(state(recording: 65))).contains(.startMeeting))
    }

    /// The stop row is always there while recording — the owner's always-visible stop.
    /// Mutation: MeetingMenu.rows, swap the two branches' actions -> RED.
    func testTheStopRowShowsTheClock() {
        let r = rows(state(recording: 754))
        guard case .item(let title, _, _, .stopMeeting)? = r.first else { return XCTFail("first row = \(String(describing: r.first))") }
        XCTAssertEqual(title, "Stop (12:34)")
    }

    func testTheDownloadRowFollowsTheDaemon() {
        XCTAssertTrue(actions(rows(state(notes: NotesStatus(reasonCode: "model_missing")))).contains(.installNotesModel))
        XCTAssertFalse(actions(rows(state(notes: NotesStatus(available: true)))).contains(.installNotesModel))
        XCTAssertFalse(actions(rows(state(notes: NotesStatus(reasonCode: "unsupported")))).contains(.installNotesModel))
        let busy = rows(state(notes: NotesStatus(reasonCode: "model_missing", installing: true, progressPercent: 40)))
        XCTAssertFalse(actions(busy).contains(.installNotesModel))
    }

    func testRetentionRowsMarkTheCurrentPick() {
        let r = rows(state())
        let on = r.compactMap { row -> Int? in
            if case .item(_, true, _, .pickMeetingRetention(let d)) = row { return d } else { return nil }
        }
        XCTAssertEqual(on, [30])
        XCTAssertEqual(actions(r).filter { if case .pickMeetingRetention = $0 { return true } else { return false } }.count, 4)
    }

    func testAnUnsupportedMacGetsOneGreyRow() {
        let r = rows(state(supported: false))
        XCTAssertEqual(r.count, 1)
        guard case .item(_, _, false, nil) = r[0] else { return XCTFail("want a disabled row") }
    }

    func testBadgeClock() {
        XCTAssertEqual(MeetingBadgeModel.clock(0), "0:00")
        XCTAssertEqual(MeetingBadgeModel.clock(754), "12:34")
        XCTAssertEqual(MeetingBadgeModel.clock(3723), "1:02:03")
        XCTAssertEqual(MeetingBadgeModel.recText(elapsed: 65, format: "REC %@"), "REC 1:05")
        XCTAssertTrue(MeetingBadgeModel.showsConsentHint(elapsed: 5))
        XCTAssertFalse(MeetingBadgeModel.showsConsentHint(elapsed: 25))
    }
}
