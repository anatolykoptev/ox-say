import Foundation
import XCTest
@testable import DictationCore

/// #337.1: what a Russian user reads when a meeting call fails is the app's sentence, never the daemon's English and
/// never the description of a framework error.
final class MeetingUserErrorTests: XCTestCase {
    private let daemonEnglish = "The ox-say service is not running. Try restarting your Mac."

    /// Starting a recording, the speakers panel and the notes-model download each have a sentence of their own kind; a
    /// refusal carrying the daemon's English text is said as the general sentence.
    /// Mutation: MeetingErrorText.sentence, `default: return text(.meetingErrGeneric)` -> `return message` -> RED.
    func testADaemonRefusalNeverShowsItsEnglishForTheNewActions() {
        let ru = ShippedStrings.localizer("ru")
        for action in [MeetingAction.start, .installModel, .speakers] {
            let refused = StudioError.refused(status: 500, message: daemonEnglish)
            let said = MeetingErrorText.sentence(refused, action: action, text: ru)
            XCTAssertFalse(said.contains("ox-say service"), "\(action): \(said)")
            XCTAssertEqual(said, ru(.meetingErrGeneric), "\(action)")
        }
        XCTAssertEqual(MeetingErrorText.sentence(StudioError.daemonUnreachable, action: .start, text: ru), ru(.meetingErrDaemonDown))
    }

    private struct NoMic: UserFacingError { var userText: String }

    /// A failure the app already worded (the microphone permission) keeps its words.
    /// Mutation: MeetingErrorText.sentence, delete the `if let error = error as? UserFacingError` line -> RED.
    func testAnErrorTheAppAlreadyWordedKeepsItsWords() {
        let said = MeetingErrorText.sentence(NoMic(userText: "Allow the microphone"), action: .start, text: ShippedStrings.localizer("ru"))
        XCTAssertEqual(said, "Allow the microphone")
    }
}
