import XCTest
@testable import DictationCore

/// #191.7 — the pill cannot be onscreen while the display sleeps or the
/// session screen is locked; the window-server check then proves nothing.
final class PillVisibilityTests: XCTestCase {
    /// Mutation: return true regardless of the lock in PillVisibility.expectsOnscreen -> RED.
    func testNothingIsExpectedOnALockedOrSleepingScreen() {
        XCTAssertTrue(PillVisibility.expectsOnscreen(screenLocked: false, displayAsleep: false))
        XCTAssertFalse(PillVisibility.expectsOnscreen(screenLocked: true, displayAsleep: false))
        XCTAssertFalse(PillVisibility.expectsOnscreen(screenLocked: false, displayAsleep: true))
        XCTAssertFalse(PillVisibility.expectsOnscreen(screenLocked: true, displayAsleep: true))
    }
}
