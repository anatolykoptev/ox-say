import XCTest
@testable import DictationCore

/// "Explained" means the person acknowledged the reminder: OK pressed on the plate that showed it, or the reminder
/// notification opened. A notification that was merely handed to the system proves nothing (Focus, banner style None,
/// Notification Center closed), and a plate that was shown but not answered (recording stopped, app quit) is asked again.
final class ConsentReminderFlowTests: XCTestCase {
    /// Mutation: ConsentReminderFlow.step, `(plateShown && plateOK) || notificationOpened` -> `plateShown || notificationOpened`
    /// (a shown plate counts) -> RED; or `|| true` -> RED.
    func testTheWholeTable() {
        // (plateShown, plateOK, notificationOpened) -> explained?
        let table: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false),  // nothing surfaced, nothing answered
            (true, false, false, false),   // plate shown, not answered: recording stopped / app quit -> asked again
            (true, true, false, true),     // OK pressed on the plate
            (false, false, true, true),    // the notification was opened
            (true, false, true, true),     // shown, then opened the notification
            (true, true, true, true),
            (false, true, false, false),   // OK cannot be pressed on a plate that was never shown
            (false, true, true, true),     // (the opened notification still counts)
        ]
        for (shown, ok, opened, explained) in table {
            XCTAssertEqual(ConsentReminderFlow.step(plateShown: shown, plateOK: ok, notificationOpened: opened),
                           explained ? .explained : .askAgain, "shown=\(shown) ok=\(ok) opened=\(opened)")
        }
    }

    func testEveryCombinationIsCovered() {
        var explained = 0
        for shown in [false, true] { for ok in [false, true] { for opened in [false, true] {
            if ConsentReminderFlow.step(plateShown: shown, plateOK: ok, notificationOpened: opened) == .explained { explained += 1 }
        } } }
        XCTAssertEqual(explained, 5, "an acknowledgement is OK on a shown plate, or the opened notification, and nothing else")
    }
}
