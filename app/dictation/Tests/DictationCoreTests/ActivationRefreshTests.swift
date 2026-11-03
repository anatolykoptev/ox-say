import XCTest
@testable import DictationCore

/// Whether the app becoming active again re-reads the main window (#400: System Settings).
final class ActivationRefreshTests: XCTestCase {
    private func decide(open: Bool = true, visible: Bool = true, now: TimeInterval = 100, read: TimeInterval?) -> Bool {
        ActivationRefresh.shouldRefresh(windowOpen: open, visible: visible, now: now, lastPermissionRead: read)
    }

    func testOnlyAnOpenVisibleWindowRefreshesOnActivation() {
        XCTAssertTrue(decide(read: nil))
        XCTAssertFalse(decide(visible: false, read: nil), "covered or minimised: the visibility change reads once")
        XCTAssertFalse(decide(open: false, read: nil), "a closed window costs nothing")
        XCTAssertFalse(decide(open: false, visible: false, read: nil))
    }

    /// Opening activates the app and un-occludes the window in the same turn: one read, not two.
    func testActivationRightAfterAPermissionReadIsTheSameEvent() {
        XCTAssertFalse(decide(now: 100, read: 99.8))
        XCTAssertTrue(decide(now: 100, read: 100 - ActivationRefresh.minimumGap))
        XCTAssertTrue(decide(now: 100, read: 10))
    }

    /// The gap is the age of the permission read: a slow pass that began early and read the permissions before the
    /// person toggled and returned must not suppress the refresh. (The glue stamps at the read, not the pass start.)
    func testAPermissionReadOlderThanTheGapDoesNotSuppressTheRefresh() {
        XCTAssertTrue(decide(now: 130, read: 100), "read 30 s ago, whatever the pass is doing now")
    }

    /// A stamp from the future (clocks mixed up, or flipped arithmetic) never silences the refresh.
    func testAReadFromTheFutureIsNotTrusted() {
        XCTAssertTrue(decide(now: 100, read: 100.5))
        XCTAssertTrue(decide(now: 100, read: 500))
    }
}
