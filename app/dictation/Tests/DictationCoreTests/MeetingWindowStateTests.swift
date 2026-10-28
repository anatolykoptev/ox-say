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

    /// A model download has no meeting in the list to wait for, but the status still has to be read.
    /// A status a newer daemon added keeps the window polling only while the meeting is recent (the 4 h that tracking
    /// allows); an old one is shown neutral, with no spinner, no polling and Rename available.
    /// Mutation: MeetingInfo.inProgress(now:), drop the recency test (return `true` for `.unknown`) -> RED.
    /// Mutation: same, `guard let started else { return false }` -> `return true`; or `abs(...)` -> the bare difference -> RED.
    /// Mutation: MeetingsPolling.needed, use `!$0.settled` in place of `$0.inProgress(now: now)` -> RED.
    func testAnUnknownStatusIsPolledOnlyWhileRecent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func unknown(hoursAgo: Double?) -> MeetingInfo {
            MeetingInfo(id: "u", started: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, status: .unknown("archived"))
        }
        XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: 1)], now: now))
        XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: 3.9)], now: now))
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: 4.1)], now: now), "an old one never polls")
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: 4.1), m("a", .done)], now: now))
        XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: 4.1), m("b", .queued)], now: now),
                      "a real unsettled meeting still polls")
        XCTAssertTrue(unknown(hoursAgo: 1).inProgress(now: now))
        XCTAssertFalse(unknown(hoursAgo: 5).inProgress(now: now))
        XCTAssertFalse(unknown(hoursAgo: nil).inProgress(now: now), "a meeting with no start time is not 'recent for ever'")
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: nil)], now: now))
        XCTAssertTrue(unknown(hoursAgo: -1).inProgress(now: now), "a start an hour ahead (a wrong clock) is recent within the horizon")
        XCTAssertFalse(unknown(hoursAgo: -5).inProgress(now: now), "a start far in the future is not recent for ever")
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [unknown(hoursAgo: -5)], now: now))
        XCTAssertEqual(MeetingRowModel.status(of: unknown(hoursAgo: 1), now: now), .waiting)
        let old = MeetingRowModel.status(of: unknown(hoursAgo: 5), now: now)
        XCTAssertEqual(old, .unrecognized)
        XCTAssertFalse(old.isBusy, "no spinner")
        XCTAssertFalse(m("a", .done).inProgress(now: now))
        XCTAssertTrue(m("a", .summarizing).inProgress(now: now))
    }

    /// Mutation: MeetingsPolling.needed, drop the `.downloading` line -> RED.
    func testADownloadKeepsThePollGoingWhileTheWindowIsOpen() {
        XCTAssertTrue(MeetingsPolling.needed(visible: true, meetings: [], writer: .downloading(percent: 40)))
        XCTAssertFalse(MeetingsPolling.needed(visible: false, meetings: [], writer: .downloading(percent: 40)))
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [], writer: .ready))
        XCTAssertFalse(MeetingsPolling.needed(visible: true, meetings: [], writer: .missing))
    }

    /// A refresh asked for while one runs is not lost.
    /// Mutation: RefreshGate.request, delete `again = true` -> RED.
    func testARefreshRequestedDuringARefreshRunsAgain() {
        var gate = RefreshGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request(), "one read at a time")
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish(), "the requests that came meanwhile are answered by one more pass")
        XCTAssertFalse(gate.finish(), "and then it is idle")
        XCTAssertTrue(gate.request(), "a later request starts at once")
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

    /// A 409 means "busy" and says what the user was doing; 404, 400 and everything else have localized sentences of
    /// their own, and the daemon's English words never come through.
    /// Mutation: MeetingErrorText.sentence, `case (409, .delete)` returns `.meetingErrBusy` -> RED.
    func testRefusalsAreSaidInTheUsersLanguageNeverInTheDaemons() {
        func refused(_ status: Int, _ action: MeetingAction) -> String {
            MeetingErrorText.sentence(StudioError.refused(status: status, message: "daemon words in English"), action: action, text: key)
        }
        XCTAssertEqual(refused(409, .delete), "meeting.error.delete_busy")
        XCTAssertEqual(refused(409, .rename), "meeting.error.rename_busy")
        XCTAssertEqual(refused(409, .speakers), "meeting.error.busy")
        XCTAssertEqual(refused(409, .retry), "meeting.error.busy")
        XCTAssertEqual(refused(409, .finish), "meeting.error.busy", "stopping a recording the daemon is still busy with")
        XCTAssertEqual(refused(500, .finish), "meeting.error.generic", "the daemon's refusal text never reaches the pill")
        XCTAssertEqual(refused(404, .rename), "meeting.error.not_found")
        XCTAssertEqual(refused(400, .rename), "meeting.error.rename_invalid")
        XCTAssertEqual(refused(400, .settings), "meeting.error.settings_invalid")
        XCTAssertEqual(refused(500, .delete), "meeting.error.generic")
        XCTAssertEqual(refused(400, .delete), "meeting.error.generic")
        let all = MeetingErrorText.sentence(StudioError.refused(status: 418, message: "teapot"), action: .refresh, text: { _ in "ok" })
        XCTAssertFalse(all.contains("teapot"))
    }

    func testAMeetingFeatureThatCannotRunHasItsOwnSentences() {
        XCTAssertEqual(MeetingErrorText.sentence(MeetingFeatureError.needsNewerMacOS, action: .rename, text: key), "meeting.error.needs_macos")
        XCTAssertEqual(MeetingErrorText.sentence(MeetingFeatureError.switchedOff, action: .speakers, text: key), "meeting.error.off")
    }

    func testDeletingAMeetingThatIsAlreadyGoneIsNotAnError() {
        XCTAssertTrue(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 404, message: "no such meeting"), action: .delete))
        XCTAssertFalse(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 404, message: "no such meeting"), action: .rename))
        XCTAssertFalse(MeetingErrorText.isAlreadyGone(StudioError.refused(status: 409, message: ""), action: .delete))
    }

    // MARK: row reasons

    func testAFailedRowIsSaidInTheUsersLanguageNotTheDaemons() {
        var info = m("a", .failed)
        info.error = "the recording was empty"
        XCTAssertEqual(MeetingRowModel.failureSentence(of: info, text: key), "meeting.failed.generic")
        info.error = nil
        XCTAssertEqual(MeetingRowModel.failureSentence(of: info, text: key), "meeting.failed.generic")
        var late = m("b", .transcribed)
        late.notesPending = "failed"
        late.error = "model said no"
        XCTAssertEqual(MeetingRowModel.failureSentence(of: late, text: key), "meeting.notes.failed")
        late.notesPending = "model_missing"
        XCTAssertNil(MeetingRowModel.failureSentence(of: late, text: key))
        XCTAssertNil(MeetingRowModel.failureSentence(of: m("c", .done), text: key))
    }

    // MARK: titles

    /// Mutation: MeetingRowModel.displayTitle, return `title(of: info, text: text)` first -> RED.
    func testATitleTheAppGaveIsShownInTheUsersLanguage() {
        let ru: (L10nKey) -> String = { $0 == .meetingsTitleCall ? "Звонок в %@" : $0.rawValue }
        func shown(_ title: String) -> String { MeetingRowModel.displayTitle(of: MeetingInfo(id: "a", title: title, status: .done), text: ru) }
        XCTAssertEqual(shown(MeetingLimits.title(forSource: "zoom")), "Звонок в Zoom")
        XCTAssertEqual(shown(MeetingLimits.title(forSource: "teams")), "Звонок в Microsoft Teams")
        XCTAssertEqual(shown(MeetingLimits.title(forSource: "oxpulse")), "Звонок в OxPulse")
        XCTAssertEqual(shown(MeetingLimits.title(forSource: "whatsapp")), "Звонок в WhatsApp")
        XCTAssertEqual(shown(MeetingLimits.title(forSource: "meet")), "Звонок в Google Meet")
    }

    /// What the user typed is theirs.
    func testAUsersOwnTitleIsNeverReplaced() {
        let ru: (L10nKey) -> String = { $0 == .meetingsTitleCall ? "Звонок в %@" : $0.rawValue }
        func shown(_ title: String) -> String { MeetingRowModel.displayTitle(of: MeetingInfo(id: "a", title: title, status: .done), text: ru) }
        XCTAssertEqual(shown("Zoom call with Anna"), "Zoom call with Anna")
        XCTAssertEqual(shown("Roadmap"), "Roadmap")
        XCTAssertEqual(shown("zoom call"), "zoom call")
        XCTAssertEqual(shown(""), "meetings.untitled")
    }

    // MARK: links

    /// Mutation: InlineMarkdown.attributed, return `parsed` instead of `removingLinks(parsed)` -> RED.
    func testNotesNeverCarryAClickableLink() {
        let out = InlineMarkdown.attributed("Open [the invoice](https://evil.example/pay) now, <https://evil.example/x> and **bold**")
        XCTAssertFalse(out.runs.contains { $0.link != nil }, "no run may be a link")
        XCTAssertTrue(String(out.characters).contains("the invoice"))
        XCTAssertTrue(String(out.characters).contains("bold"))
        XCTAssertTrue(out.runs.contains { $0.inlinePresentationIntent != nil }, "bold is kept")
    }

    /// A Markdown image is a link too: a third party's `![a](https://…)` must carry no `imageURL` either, or a view that
    /// loads image attributes would fetch it on open.
    /// Mutation: InlineMarkdown.removingLinks, delete the `imageURL` clearing -> RED.
    func testNotesNeverCarryAnImageURL() {
        let out = InlineMarkdown.attributed("see ![the chart](https://evil.example/p.png?d=SECRET) and [x](https://evil.example/y)")
        XCTAssertFalse(out.runs.contains { $0.imageURL != nil }, "no run may load an image")
        XCTAssertFalse(out.runs.contains { $0.link != nil })
        XCTAssertTrue(String(out.characters).contains("the chart"))
    }

    /// The daemon writes every bracket of model text with a backslash (`\[` `\]`), so no link or reference can form;
    /// the Markdown engine reads the text back as typed and makes nothing of it.
    /// Mutation: none in the app (the escape is the daemon's, pinned in internal/meeting TestCleanLineEscapesBracketsAndReadsBackAsTyped);
    /// a parse that ignored `\[` would show backslashes here -> RED.
    func testEscapedBracketsReadBackAsTypedAndAreNotALink() {
        let out = InlineMarkdown.attributed("use x\\[i\\](y) and \\[r\\]: http://example.invalid/p")
        XCTAssertEqual(String(out.characters), "use x[i](y) and [r]: http://example.invalid/p")
        XCTAssertFalse(out.runs.contains { $0.link != nil || $0.imageURL != nil })
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
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "model_missing", installError: "no space")), .downloadFailed(.settingsNotesWriterDownloadOther),
                       "a failed download says so, and can be tried again")
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "unsupported")), .unavailable(.menuMeetingNotesUnsupported))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: "engine_missing")), .unavailable(.menuMeetingNotesNeedUpdate))
        XCTAssertEqual(NotesWriterState.of(NotesStatus(reasonCode: nil)), .unavailable(.menuMeetingNotesNeedUpdate),
                       "an answer with no reason is not 'ready'")
    }
}
