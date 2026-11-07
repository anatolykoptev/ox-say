import XCTest
@testable import DictationCore

/// The words the phrase list and the reel add, and the daemon answers they turn into plain sentences.
final class SpeakPhrasesCopyTests: XCTestCase {
    private let ru = ShippedStrings.localizer("ru")
    private let en = ShippedStrings.localizer("en")

    private func body(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "Conflict"]])) ?? Data()
    }

    /// The two delivery-gate 409s carry no code on the wire, only their opening words (produce_ops.go).
    /// Mutation: StudioClient.refusal, delete the `styling a phrase` line -> RED.
    func testAMoodRefusedByTheDeliveryGateIsOnePlainError() {
        for message in ["styling a phrase needs clone_mode reference; create the project with clone_mode reference (ox-say produce --clone-mode reference)",
                        "styling a phrase cannot apply: the project was created with clone_mode ultimate"] {
            XCTAssertEqual(StudioClient.refusal(status: 409, body: body(message)), .stylingUnavailable)
        }
        XCTAssertEqual(StudioClient.refusal(status: 409, body: body("the project must finish first: a loudness change re-assembles the finished file")),
                       .refused(status: 409, message: "the project must finish first: a loudness change re-assembles the finished file"),
                       "another 409 keeps its own words")
        XCTAssertEqual(StudioClient.refusal(status: 400, body: body("styling a phrase is odd")).self,
                       .refused(status: 400, message: "styling a phrase is odd"), "only a 409 is the gate")
    }

    func testTheGateErrorReadsInPlainWordsInBothLanguages() {
        XCTAssertTrue(StudioError.stylingUnavailable.message(text: ru).range(of: "[А-Яа-я]", options: .regularExpression) != nil)
        XCTAssertFalse(StudioError.stylingUnavailable.message(text: ru).contains("clone_mode"))
        XCTAssertFalse(StudioError.stylingUnavailable.message(text: en).contains("clone_mode"))
        XCTAssertEqual(SpeakText.notice(StudioError.stylingUnavailable, ru), StudioError.stylingUnavailable.message(text: ru))
    }

    func testAWaitThatEndedBadlySaysSoInPlainWords() {
        XCTAssertEqual(SpeakText.notice(JobWait.Failure.renderFailed, ru), "Фразу не удалось переделать.")
        XCTAssertEqual(SpeakText.notice(JobWait.Failure.renderStopped, en), "The work on the phrase was stopped.")
        XCTAssertEqual(SpeakText.notice(JobWait.Failure.gone, ru), "Этот проект больше не найден: его удалили.")
        XCTAssertEqual(SpeakText.notice(JobWait.Failure.gaveUp, ru), ru(.speakErrorTimeout))
    }

    /// 94 characters read in seven seconds: the line says seconds, not «примерно 1 мин.». From a minute it counts minutes.
    /// Mutation: SpeakText.duration, `if seconds < 60` -> `if false` -> RED.
    func testAShortTextIsCountedInSecondsNotRoundedUpToAMinute() {
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "а", count: 94), ru), "Символов: 94 · примерно 7 с")
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "a", count: 94), en), "94 characters · about 7 sec")
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "а", count: 1000), ru), "Символов: 1000 · примерно 1 мин.")
        XCTAssertEqual(SpeakText.statusLine(editorText: String(repeating: "а", count: 2000), ru), "Символов: 2000 · примерно 2 мин.")
        XCTAssertEqual(SpeakText.statusLine(editorText: "а", ru), "Символов: 1 · примерно 1 с")
    }

    func testTheFinishLineNoLongerSendsThePersonToAFolder() {
        for t in [ru, en] {
            XCTAssertFalse(t(.speakFinishReviewOne).contains("папк") || t(.speakFinishReviewOne).contains("folder"))
            XCTAssertFalse(t(.speakFinishReviewMany).contains("папк") || t(.speakFinishReviewMany).contains("folder"))
        }
        XCTAssertEqual(StudioMenu.newVoiceoverTitle(text: ru), "Открыть Озвучку…")
        XCTAssertEqual(StudioMenu.newVoiceoverTitle(text: en), "Open Voiceover…")
    }
}
