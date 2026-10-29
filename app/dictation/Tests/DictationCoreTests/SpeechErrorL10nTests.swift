import Foundation
import XCTest
@testable import DictationCore

/// #346: the speak, playback and dictation failures reach the user in the user's language. `description` stays
/// English for the log; `message(text:)` is what a pill or notice shows.
final class SpeechErrorL10nTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let ru = ShippedStrings.localizer("ru")

    private func hasCyrillic(_ s: String) -> Bool { s.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil }

    private let speechCases: [SpeechError] = [
        .daemonUnreachable("Could not connect to the server."), .timedOut, .http(502, #"{"error":{"message":"engine busy"}}"#),
        .badResponse, .runaway, .runawayRetried,
    ]
    private let transcriptionCases: [TranscriptionError] = [
        .daemonUnreachable("Could not connect to the server."), .timedOut, .http(503, "queue full"), .badResponse,
    ]

    /// Mutation: SpeechError.message, return `description` for `.timedOut` -> RED (the ru text stays English).
    func testEverySpeechErrorReadsInRussianAndNeverShowsTheEnglishLogText() {
        for error in speechCases {
            let ruText = error.message(text: ru)
            XCTAssertTrue(hasCyrillic(ruText), "\(error): ru message is not Russian: \(ruText)")
            XCTAssertNotEqual(ruText, error.description, "\(error): the log text reached the user")
            XCTAssertNotEqual(error.message(text: en), error.message(text: ru), "\(error): en and ru are the same")
            XCTAssertFalse(ruText.contains("{"), "\(error): raw JSON reached the user")
            XCTAssertFalse(ruText.contains("Could not connect"), "\(error): the system's English reason reached the user")
        }
    }

    func testAnHttpFailureNamesTheStatusAndKeepsTheBodyOutOfTheSentence() {
        let message = SpeechError.http(502, #"{"error":{"message":"engine busy"}}"#).message(text: en)
        XCTAssertTrue(message.contains("502"), message)
        XCTAssertFalse(message.contains("engine busy"), message)
    }

    /// Mutation: SpeechError.description, `.runaway` back to `L10nKey.noticeSpeechRunaway.text` -> RED (a localized
    /// sentence in the log text; the log is English).
    func testTheLogTextStaysEnglishForEveryCase() {
        for error in speechCases { XCTAssertFalse(hasCyrillic(error.description), "\(error)") }
        XCTAssertNotEqual(SpeechError.runaway.description, L10nKey.noticeSpeechRunaway.text, "the log text is the bundle's localized sentence")
        XCTAssertEqual(SpeechError.runaway.message(text: en), en(.noticeSpeechRunaway))
    }

    /// Mutation: SpeechError.plain, `?? text(.noticeErrorFallback)` -> `?? String(describing: error)` -> RED.
    func testAnUntypedErrorGetsTheFallbackNotItsDescription() {
        struct Odd: Error, CustomStringConvertible { var description: String { "Odd internal failure" } }
        XCTAssertEqual(SpeechError.plain(Odd(), text: ru), ru(.noticeErrorFallback))
        XCTAssertEqual(SpeechError.plain(SpeechError.timedOut, text: ru), SpeechError.timedOut.message(text: ru))
        XCTAssertTrue(hasCyrillic(ru(.noticeErrorFallback)))
    }

    /// Mutation: SpeechError.plain, drop the `whilePlaying` branch -> RED.
    func testAFailureWhilePlayingSaysThePlaybackFailed() {
        struct Odd: Error {}
        XCTAssertEqual(SpeechError.plain(Odd(), whilePlaying: true, text: ru), ru(.playFailed))
        XCTAssertEqual(SpeechError.plain(SpeechError.timedOut, whilePlaying: false, text: ru), SpeechError.timedOut.message(text: ru))
    }

    func testEveryTranscriptionErrorReadsInRussianAndNeverShowsTheEnglishLogText() {
        for error in transcriptionCases {
            let ruText = error.message(text: ru)
            XCTAssertTrue(hasCyrillic(ruText), "\(error): \(ruText)")
            XCTAssertNotEqual(ruText, error.description)
            XCTAssertNotEqual(error.message(text: en), ruText)
            XCTAssertFalse(ruText.contains("queue full") || ruText.contains("Could not connect"), ruText)
        }
        XCTAssertTrue(TranscriptionError.http(503, "queue full").message(text: en).contains("503"))
    }

    func testAnUntypedTranscriptionErrorGetsTheFallback() {
        struct Odd: Error, CustomStringConvertible { var description: String { "Odd internal failure" } }
        XCTAssertEqual(TranscriptionError.plain(Odd(), text: ru), ru(.noticeErrorFallback))
    }

    /// The dictation sink: the controller hands `onError` the localized sentence, and the real error to `onErrorDetail`.
    /// Mutation: DictationController (the `.failure` arm), `onError?(String(describing: error))` -> RED.
    @MainActor
    func testADictationFailureIsReportedInTheUsersLanguageAndTheRealErrorIsLogged() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var errors: [String] = []
        var details: [Error] = []
        let c = DictationController(recorder: rec, output: out) { _ in throw TranscriptionError.timedOut }
        c.localize = ru
        c.onError = { errors.append($0) }
        c.onErrorDetail = { details.append($0) }
        c.keyDown(); c.keyUp()
        let deadline = Date().addingTimeInterval(2)
        while c.state != .idle && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(errors, [TranscriptionError.timedOut.message(text: ru)])
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details.first as? TranscriptionError, .timedOut)
    }

    /// Every `onError` call site hands the real error to `onErrorDetail` (the log): a failed recording start would otherwise
    /// leave no trace of its cause. Mutation: DictationController `prepare()` catch, delete `onErrorDetail?(error)` -> RED.
    @MainActor
    func testAFailedPrepareLogsTheRealError() {
        struct NoMic: Error, Equatable {}
        let rec = FakeRecorder(); rec.prepareError = NoMic()
        var errors: [String] = []
        var details: [Error] = []
        let c = DictationController(recorder: rec, output: FakeOutput()) { _ in "" }
        c.localize = en
        c.onError = { errors.append($0) }
        c.onErrorDetail = { details.append($0) }
        c.keyDown()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(details.map { $0 as? NoMic }, [NoMic()], "the cause of a refused recording never reached the log")
    }

    /// Mutation: DictationController `recorder.start()` catch, delete `onErrorDetail?(error)` -> RED.
    @MainActor
    func testAFailedRecordingStartLogsTheRealError() {
        struct NoMic: Error, Equatable {}
        let rec = FakeRecorder(); rec.startError = NoMic()
        var errors: [String] = []
        var details: [Error] = []
        let c = DictationController(recorder: rec, output: FakeOutput()) { _ in "" }
        c.localize = en
        c.onError = { errors.append($0) }
        c.onErrorDetail = { details.append($0) }
        c.keyDown()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(details.map { $0 as? NoMic }, [NoMic()], "the cause of a failed recording start never reached the log")
        XCTAssertEqual(c.state, .idle)
    }

    func testTheSlowerPathReasonFitsThePill() {
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "stopped", text: en), "ox-say service off — slower")
        XCTAssertLessThanOrEqual(ru(.slowSlowerPath).count, 32)
        XCTAssertLessThanOrEqual(en(.slowSlowerPath).count, 32)
    }

    // MARK: the glue, read as text (AppKit cannot run under the shim)

    private func appDelegate() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"), encoding: .utf8))
    }

    /// The sentence is for the user; the cause goes to the log at every site, or a failure would leave no trace.
    /// Mutation: AppDelegate.speakRequest, delete the `errorLog.error("speak failed` line -> RED (likewise the two others).
    func testEachSiteLogsTheRealErrorAndShowsASentence() throws {
        let source = try appDelegate()
        for want in ["controller.onErrorDetail = { [weak self] error in", #"errorLog.error("dictation failed: "#,
                     #"errorLog.error("speak failed (playing="#, "self.notice(SpeechError.plain(error, whilePlaying: playing))",
                     #"errorLog.error("voiceover playback failed: "#, "self.notice(L10nKey.playFailed.text)"] {
            XCTAssertTrue(source.contains(want), "AppDelegate lost: \(want)")
        }
    }

    // MARK: the microphone (RecorderError) at both controller sites

    func testEveryRecorderErrorReadsInRussian() {
        for error in [RecorderError.noInput, .notAllowed, .askedForPermission] {
            let ruText = error.message(text: ru)
            XCTAssertTrue(hasCyrillic(ruText), "\(error): \(ruText)")
            XCTAssertNotEqual(ruText, error.errorDescription)
            XCTAssertNotEqual(error.message(text: en), ruText)
            XCTAssertEqual(error.message(text: en), error.errorDescription, "the en sentence is the old text")
        }
    }

    @MainActor
    private func recordFailure(prepare: Error? = nil, start: Error? = nil, localize: @escaping (L10nKey) -> String) -> [String] {
        let rec = FakeRecorder(); rec.prepareError = prepare; rec.startError = start
        var errors: [String] = []
        let c = DictationController(recorder: rec, output: FakeOutput()) { _ in "" }
        c.localize = localize
        c.onError = { errors.append($0) }
        c.keyDown()
        return errors
    }

    /// Mutation: DictationController `prepare()` catch, `RecorderError.reason(error, text: localize)` ->
    /// `error.localizedDescription` -> RED (the English LocalizedError text reaches the pill).
    @MainActor
    func testAPrepareFailureReadsInTheUsersLanguage() {
        for error in [RecorderError.noInput, .notAllowed, .askedForPermission] {
            XCTAssertEqual(recordFailure(prepare: error, localize: ru), [String(format: ru(.noticeRecordFailed), error.message(text: ru))])
            XCTAssertEqual(recordFailure(prepare: error, localize: en), [String(format: en(.noticeRecordFailed), error.message(text: en))])
        }
    }

    /// Mutation: DictationController `recorder.start()` catch, same replacement -> RED.
    @MainActor
    func testAStartFailureReadsInTheUsersLanguage() {
        for error in [RecorderError.noInput, .notAllowed, .askedForPermission] {
            XCTAssertEqual(recordFailure(start: error, localize: ru), [String(format: ru(.noticeRecordFailed), error.message(text: ru))])
        }
    }

    /// Any other error (AVFoundation's, English on a Russian Mac) gets the localized fallback, never its own words.
    @MainActor
    func testAnotherRecorderErrorGetsTheFallbackAtBothSites() {
        struct Odd: Error, LocalizedError { var errorDescription: String? { "The operation couldn't be completed." } }
        let want = [String(format: ru(.noticeRecordFailed), ru(.noticeErrorFallback))]
        XCTAssertEqual(recordFailure(prepare: Odd(), localize: ru), want)
        XCTAssertEqual(recordFailure(start: Odd(), localize: ru), want)
    }

    // MARK: speak limits (#346 review)

    /// The limit is the daemon's own: pinned against internal/daemon/speak.go.
    func testTheTextLimitIsTheDaemonsLimit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let go = try String(contentsOf: root.appendingPathComponent("internal/daemon/speak.go"), encoding: .utf8)
        let m = try XCTUnwrap(go.range(of: #"const maxSpeakChars = \d+"#, options: .regularExpression), "maxSpeakChars not found")
        XCTAssertEqual(Int(go[m].split(separator: " ").last ?? ""), SpeechClient.maxInputChars)
    }

    /// Mutation: SpeechClient.speak, delete the `.tooLong` pre-check -> RED (the request is sent).
    func testATextOverTheLimitIsRefusedBeforeTheRequest() async {
        var sent = 0
        let client = SpeechClient { req in sent += 1; return (Data("RIFF".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let long = String(repeating: "я", count: SpeechClient.maxInputChars + 1)
        do {
            _ = try await client.speak(long)
            XCTFail("a text over the limit must throw")
        } catch let error as SpeechError {
            XCTAssertEqual(error, .tooLong(max: SpeechClient.maxInputChars))
            XCTAssertTrue(error.message(text: ru).contains("5000"), error.message(text: ru))
            XCTAssertTrue(hasCyrillic(error.message(text: ru)))
            XCTAssertEqual(error.message(text: en), "Text too long — select less (max 5000 characters).")
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(sent, 0, "the request went out")
        _ = try? await client.speak(String(repeating: "я", count: SpeechClient.maxInputChars))
        XCTAssertEqual(sent, 1, "a text exactly at the limit is sent")
    }

    /// Mutation: SpeechClient.failure, delete the `status == 503` line -> RED.
    func testA503BecomesTheEngineNotReadySentence() async {
        let client = SpeechClient { req in (Data("engine failed to start: boom".utf8), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!) }
        do {
            _ = try await client.speak("hi")
            XCTFail("a 503 must throw")
        } catch let error as SpeechError {
            XCTAssertEqual(error, .engineUnavailable)
            XCTAssertTrue(hasCyrillic(error.message(text: ru)))
            XCTAssertFalse(error.message(text: ru).contains("503"))
        } catch { XCTFail("\(error)") }
        let other = SpeechClient { req in (Data("x".utf8), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!) }
        do { _ = try await other.speak("hi"); XCTFail() } catch let error as SpeechError {
            XCTAssertEqual(error, .http(500, "x"))
        } catch { XCTFail("\(error)") }
    }

    // MARK: the log keeps a body private

    /// Mutation: LogDetail.publicText, return `e.description` for `.http` -> RED.
    func testAnHttpBodyIsNeverInThePublicLogText() {
        let body = "echo: my private words"
        for error in [SpeechError.http(400, body) as Error, TranscriptionError.http(400, body)] {
            let pub = LogDetail.publicText(error)
            XCTAssertFalse(pub.contains("private words"), pub)
            XCTAssertTrue(pub.contains("400") && pub.contains("bodyBytes=\(body.utf8.count)"), pub)
            XCTAssertEqual(LogDetail.privateText(error), body)
        }
        XCTAssertEqual(LogDetail.publicText(SpeechError.timedOut), SpeechError.timedOut.description)
        XCTAssertEqual(LogDetail.privateText(SpeechError.timedOut), "")
    }

    /// Mutation: AppDelegate, a log line back to `String(describing: error), privacy: .public` -> RED.
    func testNoAppDelegateLogLineWritesAnErrorsDescriptionPublicly() throws {
        let source = try appDelegate()
        XCTAssertFalse(source.contains("String(describing: error), privacy: .public"))
        XCTAssertEqual(source.components(separatedBy: "LogDetail.publicText(error), privacy: .public").count - 1, 3)
        XCTAssertEqual(source.components(separatedBy: "LogDetail.privateText(error), privacy: .private").count - 1, 3)
    }

    /// #346: a daemon refusal carries the daemon's own words (a meeting id, a file name): status and size are public,
    /// the words only private.
    /// Mutation: LogDetail.publicText, delete the `StudioError` arm -> RED.
    func testARefusalsWordsAreNeverInThePublicLogText() {
        let words = "no such meeting: standup-with-anna.m4a"
        let refused: Error = StudioError.refused(status: 404, message: words)
        let pub = LogDetail.publicText(refused)
        XCTAssertFalse(pub.contains("standup"), pub)
        XCTAssertTrue(pub.contains("404") && pub.contains("messageBytes=\(words.utf8.count)"), pub)
        XCTAssertEqual(LogDetail.privateText(refused), words)
        for plain in [StudioError.daemonUnreachable, .timedOut, .badResponse] {
            XCTAssertEqual(LogDetail.publicText(plain), plain.description)
            XCTAssertEqual(LogDetail.privateText(plain), "")
        }
    }

    private func meetingController() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/MeetingController.swift"), encoding: .utf8))
    }

    /// #346: the five error logs of the meeting controller go through LogDetail like the AppDelegate's.
    /// Mutation: MeetingController, any log line back to `String(describing: error), privacy: .public` -> RED.
    func testNoMeetingControllerLogLineWritesAnErrorsDescriptionPublicly() throws {
        let source = try meetingController()
        XCTAssertFalse(source.contains("String(describing: error), privacy: .public"))
        XCTAssertEqual(source.components(separatedBy: "LogDetail.publicText(error), privacy: .public").count - 1, 5)
        XCTAssertEqual(source.components(separatedBy: "LogDetail.privateText(error), privacy: .private").count - 1, 5)
    }

    /// #346: the microphone sentence says what is wrong in the fewest words.
    /// Mutation: ru Localizable.strings `recorder.error.no_input` back to the old sentence -> RED.
    func testTheRussianNoMicrophoneSentenceIsShort() {
        XCTAssertEqual(RecorderError.noInput.message(text: ru), "Микрофон недоступен.")
        XCTAssertEqual(RecorderError.noInput.message(text: en), "No microphone input is available.")
    }

    // MARK: one term for the daemon

    func testTheDaemonIsCalledTheOxSayServiceEverywhere() {
        let keys: [L10nKey] = [.speechErrorUnreachable, .speechErrorTimedOut, .speechErrorHttp, .speechErrorBadResponse,
                               .transcribeErrorUnreachable, .transcribeErrorTimedOut, .transcribeErrorHttp, .transcribeErrorBadResponse,
                               .slowSlowerPath, .slowOff, .slowNoAnswer]
        for key in keys {
            let e = en(key).lowercased(), r = ru(key).lowercased()
            XCTAssertTrue(e.contains("ox-say service") || e.contains("ox-say"), "\(key): \(e)")
            XCTAssertTrue(r.contains("ox-say"), "\(key): \(r)")
            for bad in ["daemon", "speech server"] { XCTAssertFalse(e.contains(bad), "\(key): \(e)") }
            for bad in ["речевой сервер", "сервер речи", "демон"] { XCTAssertFalse(r.contains(bad), "\(key): \(r)") }
        }
    }
}
