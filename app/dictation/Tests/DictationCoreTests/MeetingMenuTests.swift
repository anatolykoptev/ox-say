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

    private func titles(_ rows: [MenuRow], text: (L10nKey) -> String) -> [(String, Bool)] {
        rows.compactMap { if case .item(let t, _, let enabled, _) = $0 { return (t, enabled) } else { return nil } }
    }

    /// A failed download says why in a disabled row, in the app's own short sentence for the daemon's code (the window has
    /// the long ones), and still offers the retry. The daemon's English text is never put in the menu.
    /// Mutation: MeetingMenu.rows, delete the `if s.notes.installError != nil` block -> RED; or title the row with
    /// `installError` instead of the sentence -> RED.
    func testAFailedDownloadShowsItsSentenceAndTheRetry() {
        let text: (L10nKey) -> String = { $0.rawValue }
        let cases: [(String?, L10nKey)] = [
            ("network", .menuMeetingInstallFailedNetwork), ("disk_full", .menuMeetingInstallFailedDisk),
            ("checksum", .menuMeetingInstallFailedChecksum), ("server", .menuMeetingInstallFailedServer),
            ("other", .menuMeetingInstallFailedOther),
            ("from_the_future", .menuMeetingInstallFailedOther), (nil, .menuMeetingInstallFailedOther),
        ]
        for (code, key) in cases {
            let r = MeetingMenu.rows(state(notes: NotesStatus(reasonCode: "model_missing", installError: "The download failed: curl: (6) Could not resolve host",
                                                              installErrorCode: code)), text: text)
            let t = titles(r, text: text)
            guard let failed = t.firstIndex(where: { $0.0 == key.rawValue }) else { return XCTFail("\(code ?? "nil"): no sentence row: \(t)") }
            XCTAssertFalse(t[failed].1, "the error row is not clickable")
            XCTAssertFalse(t.contains { $0.0.contains("curl") }, "no daemon text in the menu")
            XCTAssertTrue(actions(r).contains(.installNotesModel), "the Download row is still there")
            let install = t.firstIndex { $0.0 == L10nKey.menuMeetingInstallModel.rawValue }
            XCTAssertNotNil(install)
            XCTAssertGreaterThan(install ?? 0, failed, "error first, then the retry")
        }
        // A download in flight shows progress, not the old error.
        let busy = MeetingMenu.rows(state(notes: NotesStatus(reasonCode: "model_missing", installing: true, progressPercent: 3,
                                                             installError: "disk full", installErrorCode: "disk_full")), text: text)
        XCTAssertFalse(titles(busy, text: text).contains { $0.0 == L10nKey.menuMeetingInstallFailedDisk.rawValue })
    }

    /// An engine that is missing or a Mac that cannot run notes says so, greyed.
    /// Mutation: MeetingMenu.unavailableKey, return nil for "engine_missing" -> RED.
    func testAnUnavailableNotesEngineGetsAnExplanatoryRow() {
        for (code, key) in [("engine_missing", L10nKey.menuMeetingNotesNeedUpdate), ("unsupported", .menuMeetingNotesUnsupported)] {
            let r = rows(state(notes: NotesStatus(reasonCode: code)))
            let t = titles(r, text: { $0.rawValue })
            guard let row = t.first(where: { $0.0 == key.rawValue }) else { return XCTFail("\(code): no row in \(t)") }
            XCTAssertFalse(row.1)
            XCTAssertFalse(actions(r).contains(.installNotesModel))
        }
        let ok = titles(rows(state(notes: NotesStatus(available: true))), text: { $0.rawValue })
        XCTAssertFalse(ok.contains { $0.0 == L10nKey.menuMeetingNotesNeedUpdate.rawValue || $0.0 == L10nKey.menuMeetingNotesUnsupported.rawValue })
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
