import XCTest
@testable import DictationCore

/// The daemon's English sentences must not reach the page: the 409 carries a code (`running_id`), the 400 for a missing
/// voice carries none, so its opening words are matched at the client edge and nowhere else.
final class SpeakStudioErrorTests: XCTestCase {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testTheBusyAnswerIsRecognisedByItsRunningIdNotByItsWords() {
        let busy = body(#"{"error":{"message":"another voiceover is being produced (20261001-000000-aaaaaa): wait for it or cancel it","type":"Conflict"},"running_id":"20261001-000000-aaaaaa"}"#)
        XCTAssertEqual(StudioClient.refusal(status: 409, body: busy), .voiceoverRunning)
        // The same 409 with other words still maps: the code is what counts.
        XCTAssertEqual(StudioClient.refusal(status: 409, body: body(#"{"error":{"message":"x","type":"Conflict"},"running_id":"j"}"#)), .voiceoverRunning)
        // Other 409s carry no running_id and keep their own handling.
        let cancelling = body(#"{"error":{"message":"this voiceover is still cancelling, try again in a moment","type":"Conflict"}}"#)
        XCTAssertEqual(StudioClient.refusal(status: 409, body: cancelling),
                       .refused(status: 409, message: "this voiceover is still cancelling, try again in a moment"))
    }

    func testAMissingSavedVoiceIsRecognisedDespiteThePlainWordsFilter() {
        let raw = body(#"{"error":{"message":"produce needs a saved voice: design one with voice_design or add one with voice_add","type":"Bad Request"}}"#)
        XCTAssertEqual(StudioClient.refusal(status: 400, body: raw), .noSavedVoice)
        XCTAssertEqual(StudioClient.refusal(status: 400, body: body(#"{"error":{"message":"the script must have 1 characters","type":"Bad Request"}}"#)),
                       .refused(status: 400, message: "the script must have 1 characters"))
        XCTAssertEqual(StudioClient.refusal(status: 500, body: raw), .refused(status: 500, message: ""),
                       "only a 400 means this; the filter drops the jargon sentence")
    }

    func testThePageSentencesAreTheShippedOnesWithNoIdAndNoCancel() {
        for lang in ["en", "ru"] {
            let t = ShippedStrings.localizer(lang)
            for error in [StudioError.voiceoverRunning, .noSavedVoice] {
                let sentence = error.message(text: t)
                XCTAssertFalse(sentence.isEmpty)
                XCTAssertNotEqual(sentence, error.description, "\(lang): not the English log text")
                XCTAssertFalse(sentence.contains("2026"), "no raw id")
                XCTAssertFalse(sentence.lowercased().contains("cancel") || sentence.lowercased().contains("отмен"),
                               "the page has no Stop control to cancel with")
            }
            XCTAssertEqual(StudioError.plain(StudioError.voiceoverRunning, text: t), StudioError.voiceoverRunning.message(text: t))
        }
        XCTAssertNotEqual(StudioError.voiceoverRunning.message(text: ShippedStrings.localizer("ru")),
                          StudioError.voiceoverRunning.message(text: ShippedStrings.localizer("en")))
    }
}
