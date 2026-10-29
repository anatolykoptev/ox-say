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
        .badResponse, .runaway,
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

    func testTheSlowerPathReasonFitsThePill() {
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "stopped", text: en), "speech server off — slower")
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
}
