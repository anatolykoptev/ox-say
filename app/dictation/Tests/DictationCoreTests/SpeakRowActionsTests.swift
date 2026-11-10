import XCTest
@testable import DictationCore

/// What a voiceover's row offers (window Task 18): stop, battery, resume, finish. The alerts of the Studio menu are gone, so
/// every one of these is a button in the window; stop and remove ask first, inside the window.
final class SpeakRowActionsTests: XCTestCase {
    private func job(_ status: ProduceStatus, wav: String? = nil, review: Int = 0, error: String? = nil) -> ProduceJob {
        ProduceJob(id: "20261110-101500-abc123", title: "T", status: status, partsTotal: 4, partsDone: 2, partsToReview: review,
                   error: error, outputPath: wav)
    }

    func testRunningOffersStopAndABatteryPauseOffersContinue() {
        XCTAssertEqual(SpeakRowActions.of(job: job(.running)), [.stop])
        XCTAssertEqual(SpeakRowActions.of(job: job(.waitingForDictation)), [.stop])
        XCTAssertEqual(SpeakRowActions.of(job: job(.pausedOnBattery)), [.continueOnBattery, .stop])
    }

    func testReviewNamesHowManyPartsNeedAListen() {
        let actions = SpeakRowActions.of(job: job(.review, wav: "/x/a.wav", review: 3))
        XCTAssertEqual(actions.first, .listenToFlagged(3))
        XCTAssertTrue(actions.contains(.showInFinder) && actions.contains(.save))
        XCTAssertTrue(SpeakRowAction.listenToFlagged(3).title(ShippedStrings.localizer("en")).contains("3"))
    }

    func testDoneOffersFinderAndSave() {
        XCTAssertEqual(SpeakRowActions.of(job: job(.done, wav: "/x/a.wav")), [.showInFinder, .save, .remove])
        XCTAssertEqual(SpeakRowActions.of(job: job(.done)), [.remove], "no file, nothing to show or save")
    }

    func testInterruptedOffersResume() {
        XCTAssertEqual(SpeakRowActions.of(job: job(.interrupted)), [.resume, .remove])
        XCTAssertEqual(SpeakRowActions.of(job: job(.failed, error: "x")), [.remove])
        XCTAssertEqual(SpeakRowActions.of(job: job(.cancelled)), [.remove])
    }

    func testOnlyStopAndRemoveAskFirst() {
        XCTAssertTrue(SpeakRowAction.stop.needsConfirmation)
        XCTAssertTrue(SpeakRowAction.remove.needsConfirmation)
        for a in [SpeakRowAction.continueOnBattery, .resume, .showInFinder, .save, .listenToFlagged(1)] {
            XCTAssertFalse(a.needsConfirmation, "\(a)")
        }
    }

    private func counting(status: Int = 200) -> (StudioClient, () -> [URLRequest]) {
        var seen: [URLRequest] = []
        let client = StudioClient(send: { request in
            seen.append(request)
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        return (client, { seen })
    }

    /// The journey: a running row offers Stop, the window asks, and the one confirmed answer cancels the project once.
    func testStopAsksThenCancelsOnce() async throws {
        let (client, seen) = counting()
        let running = job(.running)
        let stop = try XCTUnwrap(SpeakRowActions.of(job: running).first)
        XCTAssertTrue(stop.needsConfirmation, "the window must ask before this is sent")
        XCTAssertTrue(seen().isEmpty, "asking sends nothing")
        let handled = try await SpeakRowActions.perform(stop, id: running.id, client: client)
        XCTAssertTrue(handled)
        XCTAssertEqual(seen().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["POST /v1/produce/20261110-101500-abc123/cancel"])
    }

    func testBatteryPauseContinuesWithAllowBattery() async throws {
        let (client, seen) = counting()
        let paused = job(.pausedOnBattery)
        let action = try XCTUnwrap(SpeakRowActions.of(job: paused).first)
        _ = try await SpeakRowActions.perform(action, id: paused.id, client: client)
        let request = try XCTUnwrap(seen().first)
        XCTAssertEqual(request.url?.path, "/v1/produce/\(paused.id)/resume")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["allow_battery"] as? Bool, true)
    }

    /// An interrupted project resumes with the same id and an empty body: no battery permission is given by a plain resume.
    func testInterruptedResumesWithTheSameIDAndAnEmptyBody() async throws {
        let (client, seen) = counting()
        let cut = job(.interrupted)
        let action = try XCTUnwrap(SpeakRowActions.of(job: cut).first)
        _ = try await SpeakRowActions.perform(action, id: cut.id, client: client)
        let request = try XCTUnwrap(seen().first)
        XCTAssertEqual(request.url?.path, "/v1/produce/\(cut.id)/resume")
        XCTAssertEqual(request.httpMethod, "POST")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertTrue(json.isEmpty, "{} — never allow_battery")
    }

    func testRemoveDeletesTheProjectAndLocalActionsSendNothing() async throws {
        let (client, seen) = counting()
        _ = try await SpeakRowActions.perform(.remove, id: "p1", client: client)
        XCTAssertEqual(seen().map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["DELETE /v1/produce/p1"])
        XCTAssertEqual(seen().first?.url?.query, "delete_outputs=true", "the confirmation promises the finished files go too")
        XCTAssertEqual(seen().first?.url?.path, "/v1/produce/p1", "the query is a query, not part of the path")
        for local in [SpeakRowAction.showInFinder, .save, .listenToFlagged(2)] {
            let handled = try await SpeakRowActions.perform(local, id: "p1", client: client)
            XCTAssertFalse(handled, "\(local) is the window's own")
        }
        XCTAssertEqual(seen().count, 1)
    }

    /// The words read right in both languages (the keys exist in both files; `LocalizationTests` holds the parity).
    func testTheButtonsAndTheConfirmationsReadRightInBothLanguages() {
        let en = ShippedStrings.localizer("en"), ru = ShippedStrings.localizer("ru")
        XCTAssertEqual(SpeakRowAction.resume.title(en), "Resume")
        XCTAssertEqual(SpeakRowAction.resume.title(ru), "Продолжить")
        XCTAssertEqual(SpeakRowAction.continueOnBattery.title(ru), "Продолжить на батарее")
        XCTAssertEqual(SpeakRowAction.listenToFlagged(4).title(en), "Listen to flagged parts (4)")
        XCTAssertEqual(SpeakRowAction.stop.confirmation(ru)?.confirm, "Остановить")
        XCTAssertEqual(SpeakRowAction.remove.confirmation(en)?.title, "Delete this voiceover?")
        XCTAssertTrue(SpeakRowAction.remove.confirmation(en)?.text.contains("finished files") == true)
        XCTAssertTrue(SpeakRowAction.remove.confirmation(ru)?.text.contains("готовые файлы") == true)
        XCTAssertNil(SpeakRowAction.resume.confirmation(en))
    }

    // MARK: finish notification

    func testFinishPostsANotification() throws {
        let done = job(.done, wav: "/x/Chapter.wav")
        let en = ShippedStrings.localizer("en")
        let elsewhere = ShownWindow(appActive: true, windowVisible: true, section: .voices, speakID: nil)
        let onIt = ShownWindow(appActive: true, windowVisible: true, section: .speak, speakID: done.id)
        let notice = try XCTUnwrap(VoiceoverReady.notice(for: done, shown: elsewhere, text: en))
        XCTAssertEqual(notice.speakID, done.id)
        XCTAssertEqual(notice.title, ProduceText.finishAlert(done, text: en)?.title)
        XCTAssertTrue(notice.body.contains("Chapter.wav"))
        XCTAssertNil(VoiceoverReady.notice(for: job(.cancelled), shown: elsewhere, text: en), "a voiceover stopped on purpose earns none")
        XCTAssertNil(VoiceoverReady.notice(for: done, shown: onIt, text: en), "the window already shows it")
        var inactive = onIt; inactive.appActive = false
        XCTAssertNotNil(VoiceoverReady.notice(for: done, shown: inactive, text: en), "another app is in front")
    }

    // MARK: wiring (the app target is not importable here: the call sites are read as text, like the other wiring tests)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(path)"), encoding: .utf8)
    }

    /// Mutation: VoiceoverService.announce, delete the `MeetingNotifier.shared.voiceoverReady(notice)` call -> RED.
    func testFinishPostsANotificationAndItsClickOpensTheProject() throws {
        let service = try source("OxSayDictation/VoiceoverService.swift")
        XCTAssertTrue(service.contains("self.announce(job)"))
        XCTAssertTrue(service.contains("MeetingNotifier.shared.voiceoverReady(notice)"))
        let notifier = try source("OxSayDictation/MeetingNotifier.swift")
        XCTAssertTrue(notifier.contains("self?.openRoute(MainRoute(section: .speak, speakID: id))"))
        XCTAssertTrue(notifier.contains("info[Self.speakKey] = speakID"))
        try XCTAssertTrue(source("OxSayDictation/AppDelegate.swift").contains("MeetingNotifier.shared.openRoute = { [unowned self] route in self.mainWindow.show(route) }"))
    }

    /// The row: the buttons are `SpeakRowActions`', the dialog is window-modal and asked for the actions that need it, and the
    /// daemon's ones run through `SpeakRowActions.perform` and are followed from their new state.
    /// Mutation: SpeakPage, `if action.needsConfirmation { asking = action }` -> always `model.actions.speakRowAction(action)` -> RED.
    func testTheRowAsksInTheWindowAndRunsThroughThePerformer() throws {
        let page = try source("MainWindowUI/SpeakPage.swift")
        XCTAssertTrue(page.contains("SpeakRowActions.of(job: job)"))
        XCTAssertTrue(page.contains("if action.needsConfirmation { asking = action } else { model.actions.speakRowAction(action) }"))
        XCTAssertTrue(page.contains(".confirmationDialog("))
        let speak = try source("OxSayDictation/SpeakSource.swift")
        XCTAssertTrue(speak.contains("try await SpeakRowActions.perform(action, id: id, client: client)"))
        XCTAssertTrue(speak.contains("if action != .remove { await voiceover.refollow(id: id) }"))
        try XCTAssertTrue(source("OxSayDictation/MainWindowSource.swift").contains("a.speakRowAction = { [weak self] action in self?.speakSource.runRowAction(action) }"))
    }
}
