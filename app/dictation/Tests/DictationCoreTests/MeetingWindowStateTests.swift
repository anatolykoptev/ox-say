import Foundation
import XCTest
@testable import DictationCore

/// What the Meetings page shows, which error says what, when the window checks again, and where Show in Finder goes.
final class MeetingWindowStateTests: XCTestCase {
    private func m(_ id: String, _ status: MeetingInfo.Status) -> MeetingInfo { MeetingInfo(id: id, status: status) }
    private let key: (L10nKey) -> String = { $0.rawValue }

    // MARK: page state

    /// Mutation: MeetingsPageState.of, move the `!enabled` check below the load cases -> RED.
    func testSwitchedOffBeatsEverythingElse() {
        XCTAssertEqual(MeetingsPageState.of(enabled: false, load: .failed("x"), hasMeetings: true, recording: true), .off)
        XCTAssertEqual(MeetingsPageState.of(enabled: false, load: .loading, hasMeetings: false, recording: false), .off)
    }

    func testFirstLoadShowsLoadingUntilThereIsAnAnswer() {
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .loading, hasMeetings: false, recording: false), .loading)
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .loading, hasMeetings: true, recording: false), .list(stale: nil),
                       "a refresh never blanks a list that is already on screen")
    }

    /// The daemon down with nothing to show is a page of its own; with a list it keeps the list and says so.
    /// Mutation: MeetingsPageState.of, return `.empty` for a failed load with no meetings -> RED.
    func testADaemonThatIsDownIsNotAnEmptyList() {
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .failed("down"), hasMeetings: false, recording: false), .unreachable("down"))
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .failed("down"), hasMeetings: true, recording: false), .list(stale: "down"))
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .failed("down"), hasMeetings: false, recording: true), .list(stale: "down"),
                       "the recording bar is still shown while the daemon cannot be read")
    }

    func testEmptyOnlyWhenLoadedNothingAndNotRecording() {
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .loaded, hasMeetings: false, recording: false), .empty)
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .loaded, hasMeetings: false, recording: true), .list(stale: nil))
        XCTAssertEqual(MeetingsPageState.of(enabled: true, load: .loaded, hasMeetings: true, recording: false), .list(stale: nil))
    }

    // MARK: polling

    /// Mutation: MeetingsPolling.needed, drop the `visible` term -> RED (a closed window would keep asking).
    func testPollsOnlyWhileTheWindowIsOpenAndSomethingIsStillWorking() {
        let busy = [m("a", .done), m("b", .summarizing)]
        XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: busy))
        XCTAssertFalse(MeetingsPolling.needed(visible: false, meetings: busy), "a closed window costs nothing")
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [m("a", .done), m("b", .failed), m("c", .transcribed)]))
        for s in [MeetingInfo.Status.recording, .queued, .transcribing, .summarizing] {
            XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: [m("a", s)]), "\(s)")
        }
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: []))
    }

    // MARK: error sentences

    func testEveryTransportErrorHasASentence() {
        for action in MeetingAction.allCases {
            XCTAssertEqual(MeetingErrorText.sentence(StudioError.daemonUnreachable, action: action, text: key), "meeting.error.daemon_down")
            XCTAssertEqual(MeetingErrorText.sentence(StudioError.timedOut, action: action, text: key), "meeting.error.timeout")
            XCTAssertEqual(MeetingErrorText.sentence(StudioError.badResponse, action: action, text: key), "meeting.error.bad_response")
            XCTAssertEqual(MeetingErrorText.sentence(CancellationError(), action: action, text: key), "meeting.error.generic")
        }
    }

    /// A 409 means "busy" and says what the user was doing; any other refusal carries the daemon's words.
    /// Mutation: MeetingErrorText.sentence, delete the `.delete` 409 arm -> RED.
    func testBusyRefusalsNameTheAction() {
        func refused(_ status: Int, _ action: MeetingAction) -> String {
            MeetingErrorText.sentence(StudioError.refused(status: status, message: "daemon words"), action: action, text: key)
        }
        XCTAssertEqual(refused(409, .delete), "meeting.error.delete_busy")
        XCTAssertEqual(refused(409, .rename), "meeting.error.rename_busy")
        XCTAssertEqual(refused(409, .speakers), "meeting.error.busy")
        XCTAssertEqual(refused(409, .retry), "meeting.error.busy")
        XCTAssertEqual(refused(500, .delete), "meeting.error.refused")
        let words = MeetingErrorText.sentence(StudioError.refused(status: 400, message: "title too long"), action: .rename,
                                              text: { $0 == .meetingErrRefused ? "No: %@" : $0.rawValue })
        XCTAssertEqual(words, "No: title too long")
    }

    func testDeletingAMeetingThatIsAlreadyGoneIsNotAnError() {
        XCTAssertTrue(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 404, message: "no such meeting"), action: .delete))
        XCTAssertFalse(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 404, message: "no such meeting"), action: .rename))
        XCTAssertFalse(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 409, message: ""), action: .delete))
    }

    // MARK: row reasons

    func testAFailedRowGivesTheDaemonsReasonInPlainWords() {
        var info = m("a", .failed)
        info.error = "the recording was empty"
        XCTAssertEqual(MeetingRowModel.failureReason(of: info), "the recording was empty")
        info.error = "transcription failed: `ox-say status` shows OX_SAY_STT missing"
        XCTAssertNil(MeetingRowModel.failureReason(of: info), "jargon the user cannot act on is not shown")
        info.error = nil
        XCTAssertNil(MeetingRowModel.failureReason(of: info))
        var done = m("b", .done)
        done.error = "stale"
        XCTAssertNil(MeetingRowModel.failureReason(of: done), "only a recording that did not finish has a reason line")
    }

    // MARK: Show in Finder

    func testShowInFinderPrefersTheMeetingsCopyThenTheFolderThenSaysSo() {
        let folder = URL(fileURLWithPath: "/Notes", isDirectory: true)
        let both: (String) -> Bool = { _ in true }
        XCTAssertEqual(MeetingFolderTarget.resolve(exportPath: "/Notes/2026-10-23 Plan", notesFolder: folder, exists: both),
                       .copy(URL(fileURLWithPath: "/Notes/2026-10-23 Plan", isDirectory: true)))
        XCTAssertEqual(MeetingFolderTarget.resolve(exportPath: "/Notes/gone", notesFolder: folder, exists: { $0 == "/Notes" }), .notesFolder(folder))
        XCTAssertEqual(MeetingFolderTarget.resolve(exportPath: nil, notesFolder: folder, exists: { $0 == "/Notes" }), .notesFolder(folder))
        XCTAssertEqual(MeetingFolderTarget.resolve(exportPath: nil, notesFolder: folder, exists: { _ in false }), .nowhere)
    }
}
