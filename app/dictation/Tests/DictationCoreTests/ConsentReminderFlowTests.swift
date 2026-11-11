import XCTest
@testable import DictationCore

/// The one-time consent reminder counts as given only once its BODY has been surfaced (Codex review of cb38f0f): a
/// notification that was delivered, else the plate; never the title alone, never before either.
final class ConsentReminderFlowTests: XCTestCase {
    /// Mutation: ConsentReminderFlow.afterPost, `delivered ? .explained : .showOnPlate` -> `.explained` -> RED.
    func testADeliveredNotificationIsExplainedAndADeniedOneGoesToThePlate() {
        XCTAssertEqual(ConsentReminderFlow.afterPost(delivered: true), .explained)
        XCTAssertEqual(ConsentReminderFlow.afterPost(delivered: false), .showOnPlate)
    }

    /// Mutation: ConsentReminderFlow.afterPlate, `shown ? .explained : .askAgain` -> `.explained` -> RED.
    func testThePlateCountsOnlyWhenItWasActuallyShown() {
        XCTAssertEqual(ConsentReminderFlow.afterPlate(shown: true), .explained)
        XCTAssertEqual(ConsentReminderFlow.afterPlate(shown: false), .askAgain, "neither surfaced: asked again next time")
    }

    func testTheWholeTable() {
        // (delivered, plateShown) -> explained?
        for (delivered, shown, explained) in [(true, nil, true), (false, true, true), (false, false, false)] as [(Bool, Bool?, Bool)] {
            var step = ConsentReminderFlow.afterPost(delivered: delivered)
            if step == .showOnPlate, let shown { step = ConsentReminderFlow.afterPlate(shown: shown) }
            XCTAssertEqual(step == .explained, explained, "delivered=\(delivered) shown=\(String(describing: shown))")
        }
    }
}
