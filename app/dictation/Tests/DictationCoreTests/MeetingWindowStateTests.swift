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

/// The window's reads and deletes against a fake daemon.
final class MeetingWindowServiceTests: XCTestCase {
    private let key: (L10nKey) -> String = { $0.rawValue }

    private func service(status: Int = 200, answers: [String: String] = [:], down: Bool = false,
                         record: ((URLRequest) -> Void)? = nil) -> MeetingWindowService {
        MeetingWindowService(client: StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            if down { throw URLError(.cannotConnectToHost) }
            let body = answers[request.url?.path ?? ""] ?? "{}"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }

    // MARK: delete

    func testADeletedMeetingIsDone() async {
        var seen: URLRequest?
        let outcome = await service(status: 204, record: { seen = $0 }).delete(id: "a", text: key)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(seen?.httpMethod, "DELETE")
    }

    /// A 409 (still recording or processing) must reach the user, not read as a delete that worked.
    /// Mutation: MeetingWindowService.delete, `catch` returns `.done` -> RED.
    func testABusyMeetingIsNotDeletedAndTheUserIsTold() async {
        let outcome = await service(status: 409, answers: ["/v1/meetings/a": #"{"error":{"message":"busy"}}"#]).delete(id: "a", text: key)
        XCTAssertEqual(outcome, .failed("meeting.error.delete_busy"))
    }

    func testAMeetingThatWasAlreadyGoneIsGone() async {
        let outcome = await service(status: 404).delete(id: "a", text: key)
        XCTAssertEqual(outcome, .alreadyGone)
    }

    func testDeleteWithTheDaemonDownSaysSo() async {
        let outcome = await service(down: true).delete(id: "a", text: key)
        XCTAssertEqual(outcome, .failed("meeting.error.daemon_down"))
    }

    // MARK: list

    func testTheListIsTheDaemonsMeetings() async {
        let answer = #"{"meetings":[{"id":"a","status":"done","title":"One"},{"id":"b","status":"queued"}]}"#
        let (list, load) = await service(answers: ["/v1/meetings": answer]).list(text: key)
        XCTAssertEqual(list?.map(\.id), ["a", "b"])
        XCTAssertEqual(load, .loaded)
    }

    func testAListThatCouldNotBeReadKeepsNothingAndSaysWhy() async {
        let (list, load) = await service(down: true).list(text: key)
        XCTAssertNil(list, "nil tells the caller to keep what it already shows")
        XCTAssertEqual(load, .failed("meeting.error.daemon_down"))
    }

    // MARK: detail

    func testADetailCarriesTheTextsAndTheSpeakers() async {
        let answers = [
            "/v1/meetings/a": ##"{"id":"a","status":"done","notes_md":"# T\n\n## S\n\n- x","transcript_md":"**Me** [0:01]: hi"}"##,
            "/v1/meetings/a/speakers": #"{"mode":"auto","split":true,"speakers":[{"id":"them:1","label":"Them 1"}]}"#,
        ]
        var seen: [String] = []
        let result = await service(answers: answers, record: { seen.append($0.url?.path ?? "") }).detail(id: "a", text: key)
        guard case .success(let detail) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(detail.info.notesMD?.hasPrefix("# T"), true)
        XCTAssertEqual(detail.speakers?.speakers.map(\.id), ["them:1"])
        XCTAssertNil(detail.speakersError)
        XCTAssertTrue(seen.contains("/v1/meetings/a/speakers"))
    }

    /// The speakers of a meeting that is still being processed are not asked for; the Speakers tab is simply empty.
    func testAMeetingStillWorkingIsNotAskedForSpeakers() async {
        var seen: [String] = []
        let result = await service(answers: ["/v1/meetings/a": #"{"id":"a","status":"summarizing"}"#], record: { seen.append($0.url?.path ?? "") })
            .detail(id: "a", text: key)
        guard case .success(let detail) = result else { return XCTFail("\(result)") }
        XCTAssertNil(detail.speakers)
        XCTAssertNil(detail.speakersError)
        XCTAssertFalse(seen.contains("/v1/meetings/a/speakers"))
    }

    /// Speakers that fail to load do not hide the notes; the tab says why.
    func testSpeakersThatFailKeepTheNotes() async {
        let svc = MeetingWindowService(client: StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            if request.url?.path.hasSuffix("/speakers") == true { throw URLError(.timedOut) }
            return (Data(#"{"id":"a","status":"done","notes_md":"n"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        guard case .success(let detail) = await svc.detail(id: "a", text: key) else { return XCTFail("the meeting itself loaded") }
        XCTAssertEqual(detail.info.notesMD, "n")
        XCTAssertNil(detail.speakers)
        XCTAssertEqual(detail.speakersError, "meeting.error.timeout")
    }

    func testADetailThatCannotBeReadIsAnError() async {
        guard case .failure(let failure) = await service(down: true).detail(id: "a", text: key) else { return XCTFail("want a failure") }
        XCTAssertEqual(failure.sentence, "meeting.error.daemon_down")
    }
}

final class NotesWriterStateTests: XCTestCase {
    func testTheDaemonsNotesStatusBecomesTheRow() {
        XCTAssertEqual(NotesWriterState.of(nil), .unavailable(.meetingErrDaemonDown))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(available: true)), .ready)
        XCTAssertEqual(NotesWriterState.of(NotesStatus(installing: true, progressPercent: 41)), .downloading(percent: 41))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "model_missing")), .missing)
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "model_missing", installError: "no space")), .missing,
                       "a failed download can be tried again")
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "unsupported")), .unavailable(.menuMeetingNotesUnsupported))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "engine_missing")), .unavailable(.menuMeetingNotesNeedUpdate))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: nil)), .unavailable(.menuMeetingNotesNeedUpdate),
                       "an answer with no reason is not 'ready'")
    }
}
