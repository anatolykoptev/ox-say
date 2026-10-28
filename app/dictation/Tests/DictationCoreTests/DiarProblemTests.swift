import Foundation
import XCTest
@testable import DictationCore

final class DiarProblemTests: XCTestCase {
    func testTheDaemonsWarningAndReasonBecomeAProblem() {
        XCTAssertEqual(DiarProblem.of(warnings: ["diarization_failed"], reason: "timeout"), .failed(reason: "timeout"))
        XCTAssertEqual(DiarProblem.of(warnings: ["echo_dropped", "diarization_unavailable"], reason: "os_too_old"), .unavailable(reason: "os_too_old"))
        XCTAssertNil(DiarProblem.of(warnings: ["echo_dropped"], reason: nil))
        XCTAssertEqual(DiarProblem.of(warnings: ["diarization_failed"], reason: nil), .failed(reason: ""), "a daemon that sent no reason still shows the problem")
        let info = MeetingInfo.decode(Data(#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"models_missing"}"#.utf8))
        XCTAssertEqual(info?.diarProblem, .unavailable(reason: "models_missing"))
    }

    /// Only a failure of the engine can be tried again, and not a timeout (the same call takes as long again, after a
    /// second transcription); a Mac that cannot do it stays that way.
    /// Mutation: DiarProblem.canRetry, return true for both kinds -> RED; drop `reason != "timeout"` -> RED.
    func testOnlyAFailureThatCanChangeCanBeRetried() {
        XCTAssertTrue(DiarProblem.failed(reason: "engine_error").canRetry)
        XCTAssertTrue(DiarProblem.failed(reason: "bad_output").canRetry)
        XCTAssertFalse(DiarProblem.failed(reason: "timeout").canRetry)
        XCTAssertFalse(DiarProblem.unavailable(reason: "os_too_old").canRetry)
        XCTAssertFalse(DiarProblem.unavailable(reason: "models_unusable").canRetry)
        XCTAssertFalse(DiarProblem.unavailable(reason: "too_long").canRetry, "a recording over two hours stays over two hours")
        XCTAssertFalse(DiarProblem.unavailable(reason: "input_unreadable").canRetry, "the same file is unreadable again")
    }

    /// Every code the daemon can send has its own sentence, and a code from a newer daemon gets the general one.
    /// The codes are the Diar* constants of internal/meeting/diarize.go; a new one needs a row here and a string.
    func testEveryReasonHasItsOwnSentence() {
        let failed = ["engine_error": L10nKey.diarFailedEngine, "bad_output": .diarFailedOutput, "timeout": .diarFailedTimeout]
        for (code, key) in failed { XCTAssertEqual(DiarProblem.failed(reason: code).messageKey, key, code) }
        let unavailable = ["os_too_old": L10nKey.diarUnavailableOS, "cpu_unsupported": .diarUnavailableCPU,
                           "engine_missing": .diarUnavailableEngine, "models_missing": .diarUnavailableModels,
                           "models_unusable": .diarUnavailableUnusable,
                           "too_long": .diarUnavailableTooLong, "input_unreadable": .diarUnavailableUnreadable]
        for (code, key) in unavailable { XCTAssertEqual(DiarProblem.unavailable(reason: code).messageKey, key, code) }
        XCTAssertEqual(DiarProblem.failed(reason: "from_the_future").messageKey, .diarFailedEngine)
        XCTAssertEqual(DiarProblem.unavailable(reason: "from_the_future").messageKey, .diarUnavailableOther)
        let all = Set(failed.values).union(unavailable.values).union([.diarUnavailableOther])
        XCTAssertEqual(all.count, 11, "each sentence is its own key")
    }

    func testTheMenuListsVoicesAndProblemsNewestFirstAndSaysAMacProblemOnce() {
        let list = [
            MeetingInfo(id: "a", title: "Standup", status: .done, warnings: ["diarization_unavailable"], diarReason: "os_too_old"),
            MeetingInfo(id: "b", title: "Plan", status: .done, voiceMode: "auto"),
            MeetingInfo(id: "c", title: "One to one", status: .done),
            MeetingInfo(id: "d", title: "Retro", status: .done, warnings: ["diarization_unavailable"], diarReason: "os_too_old"),
            MeetingInfo(id: "e", title: "Sync", status: .transcribed, warnings: ["diarization_failed"], diarReason: "engine_error"),
            MeetingInfo(id: "f", title: "Running", status: .summarizing, warnings: ["diarization_failed"], diarReason: "engine_error"),
        ]
        let recent = MeetingMenuRecent.from(list)
        XCTAssertEqual(recent.map(\.id), ["a", "b", "e"], "d repeats a's Mac problem, c has nothing to say, f is not ready")
        XCTAssertEqual(recent[0].problem, .unavailable(reason: "os_too_old"))
        XCTAssertNil(recent[1].problem)
        XCTAssertEqual(MeetingMenuRecent.from(list, limit: 2).count, 2)
    }

    /// A problem is a disabled sentence; a failure also gets a "Try Again" row; voices get the naming row.
    /// Mutation: MeetingMenu.rows, change `if problem.canRetry {` to `if true {` -> RED (a Mac that cannot do it offers a retry).
    func testTheRowsForProblemsAndVoices() {
        let recent = [
            MeetingMenuRecent(id: "a", title: "Standup", problem: .unavailable(reason: "os_too_old")),
            MeetingMenuRecent(id: "b", title: "Plan"),
            MeetingMenuRecent(id: "e", title: "Sync", problem: .failed(reason: "bad_output")),
            MeetingMenuRecent(id: "t", title: "Long", problem: .failed(reason: "timeout")),
        ]
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), callMode: .ask,
                                     retention: .month, recent: recent)
        let rows = MeetingMenu.rows(state, text: { $0.rawValue })
        let items = rows.compactMap { row -> (String, Bool, MenuAction?)? in
            if case .item(let title, _, let enabled, let action) = row { return (title, enabled, action) } else { return nil }
        }
        XCTAssertTrue(items.contains { $0.0 == "meeting.diar.unavailable.os_too_old" && !$0.1 && $0.2 == nil })
        XCTAssertTrue(items.contains { $0.0 == "meeting.diar.failed.bad_output" && !$0.1 && $0.2 == nil })
        XCTAssertTrue(items.contains { $0.0 == "meeting.diar.failed.timeout" && !$0.1 && $0.2 == nil })
        let actions = items.compactMap(\.2)
        XCTAssertTrue(actions.contains(.editSpeakers("b")))
        XCTAssertTrue(actions.contains(.retryVoices("e")))
        XCTAssertTrue(items.contains { $0.2 == .editSpeakers("b") && $0.1 }, "the naming row is clickable")
        XCTAssertTrue(items.contains { $0.2 == .retryVoices("e") && $0.1 }, "the Try Again row is clickable")
        XCTAssertFalse(actions.contains(.retryVoices("a")), "nothing to retry on a Mac that cannot do it")
        XCTAssertFalse(actions.contains(.retryVoices("t")), "a timeout would only time out again")
        XCTAssertFalse(actions.contains(.editSpeakers("a")))
    }
}

final class DiarProblemClientTests: XCTestCase {
    /// "Try Again" goes to the voices route, never to the notes route: the notes retry is made by the app on its own
    /// (at launch, for a meeting waiting on the notes model) and must not cost a transcription.
    /// Mutation: MeetingClient.retryMeetingVoices, change `v1/meetings/\(id)/voices` to `v1/meetings/\(id)/notes` -> RED.
    func testRetryVoicesPostsToTheVoicesRoute() async throws {
        var seen: [URLRequest] = []
        let c = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            seen.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        try await c.retryMeetingVoices(id: "m1")
        XCTAssertEqual(seen.first?.httpMethod, "POST")
        XCTAssertEqual(seen.first?.url?.path, "/v1/meetings/m1/voices")
    }
}

/// "Try Again" for voices that were unavailable (the voice engine or its models were missing when the call was
/// recorded) is the daemon's decision: it computes `voices_retryable` per meeting from the same readiness check that
/// decides the POST, and the app shows the button exactly when it says so.
final class VoicesTryAgainTests: XCTestCase {
    private func info(_ json: String) -> MeetingInfo { MeetingInfo.decode(Data(json.utf8))! }

    /// Mutations: DiarProblem.offersRetry, `case .unavailable: return daemonSaysRetryable` -> `return false` -> RED (F4: the app
    /// ignores the daemon field and never offers a retry for unavailable voices); -> `return true` -> RED (offered while not ready).
    func testTheDecisionFollowsTheServedPayload() {
        let cases: [(String, Bool)] = [
            // unavailable, daemon says it can be retried: models arrived
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"models_missing","voices_retryable":true}"#, true),
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"engine_missing","voices_retryable":true}"#, true),
            // unavailable, models not here yet: no button, the reason text stays
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"models_missing","voices_retryable":false}"#, false),
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"models_missing"}"#, false),
            // a reason a retry cannot help stays hidden, whatever the field says is the daemon's business; the daemon sends false
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"input_unreadable","voices_retryable":false}"#, false),
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"too_long"}"#, false),
            // audio removed by retention: nothing to transcribe
            (#"{"id":"a","status":"done","warnings":["diarization_unavailable"],"diar_reason":"models_missing","voices_retryable":true,"audio_deleted":true}"#, false),
            // the failed kind keeps the app's own rule and an older daemon (no field) still works
            (#"{"id":"a","status":"done","warnings":["diarization_failed"],"diar_reason":"engine_error"}"#, true),
            (#"{"id":"a","status":"done","warnings":["diarization_failed"],"diar_reason":"timeout"}"#, false),
            // no problem, no button
            (#"{"id":"a","status":"done","voices_retryable":true}"#, false),
        ]
        for (json, want) in cases {
            XCTAssertEqual(info(json).offersVoicesRetry, want, json)
        }
    }

    /// The menu offers the row from the same decision, and keeps a retryable meeting's own row although the Mac-wide
    /// reason was already said for a newer one.
    /// Mutations: MeetingMenu.rows, `problem.offersRetry(daemonSaysRetryable: r.voicesRetryable, ...)` -> `problem.canRetry` -> RED;
    /// MeetingMenuRecent.from, delete `!m.offersVoicesRetry,` -> RED (the second retryable meeting disappears).
    func testTheMenuOffersTryAgainForARetryableUnavailableMeeting() {
        let list = [
            MeetingInfo(id: "new", title: "New", status: .done, warnings: ["diarization_unavailable"], diarReason: "models_missing"),
            MeetingInfo(id: "r1", title: "R1", status: .done, warnings: ["diarization_unavailable"], diarReason: "models_missing", voicesRetryable: true),
            MeetingInfo(id: "r2", title: "R2", status: .done, warnings: ["diarization_unavailable"], diarReason: "models_missing", voicesRetryable: true),
        ]
        let recent = MeetingMenuRecent.from(list, limit: 10)
        XCTAssertEqual(recent.map(\.id), ["new", "r1", "r2"])
        let state = MeetingMenuState(supported: true, recordingElapsed: nil, notes: NotesStatus(available: true), callMode: .ask,
                                     retention: .month, recent: recent)
        let actions = MeetingMenu.rows(state, text: { $0.rawValue }).compactMap { row -> MenuAction? in
            if case .item(_, _, _, let a) = row { return a } else { return nil }
        }
        XCTAssertTrue(actions.contains(.retryVoices("r1")))
        XCTAssertTrue(actions.contains(.retryVoices("r2")))
        XCTAssertFalse(actions.contains(.retryVoices("new")), "models still missing for this one")
    }

    /// Race: the models were ready at the check and gone at the press (the daemon answers 503 voices_not_ready): a
    /// sentence in the user's language, never the daemon's English and never the "busy" one.
    /// Mutation: MeetingErrorText.sentence, delete `case (503, .retryVoices)` -> RED (generic sentence).
    func testARefusedRetryAtPressTimeIsSaidPlainly() {
        let refused = StudioError.refused(status: 503, message: "Voices cannot be told apart yet")
        let en = ShippedStrings.localizer("en"), ru = ShippedStrings.localizer("ru")
        XCTAssertEqual(MeetingErrorText.sentence(refused, action: .retryVoices, text: en),
                       "The voice models are not ready yet. Try again when they have finished downloading.")
        XCTAssertEqual(MeetingErrorText.sentence(refused, action: .retryVoices, text: ru),
                       "Голосовые модели ещё не готовы. Попробуйте, когда они скачаются.")
        XCTAssertNotEqual(MeetingErrorText.sentence(StudioError.refused(status: 409, message: "x"), action: .retryVoices, text: en),
                          MeetingErrorText.sentence(refused, action: .retryVoices, text: en))
    }

    /// The POST goes through the existing client call with its JSON header and a 503 comes back as a refusal the
    /// sentence above reads.
    func testTheRefusalReachesTheAppAs503() async {
        let c = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            let body = #"{"error":{"message":"Voices cannot be told apart yet: the voice engine or its models are not ready.","code":"voices_not_ready","reason":"models_missing"}}"#
            return (Data(body.utf8), response)
        }
        do { try await c.retryMeetingVoices(id: "m1"); XCTFail("expected a refusal") } catch let error as StudioError {
            guard case .refused(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 503)
        } catch { XCTFail("\(error)") }
    }
}
