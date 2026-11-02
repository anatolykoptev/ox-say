import XCTest
@testable import DictationCore

/// Whether the app becoming active again re-reads the main window (#400: System Settings).
final class ActivationRefreshTests: XCTestCase {
    func testOnlyAnOpenVisibleWindowRefreshesOnActivation() {
        XCTAssertTrue(ActivationRefresh.shouldRefresh(windowOpen: true, visible: true))
        XCTAssertFalse(ActivationRefresh.shouldRefresh(windowOpen: true, visible: false), "covered or minimised: the visibility change reads once")
        XCTAssertFalse(ActivationRefresh.shouldRefresh(windowOpen: false, visible: true), "a closed window costs nothing")
        XCTAssertFalse(ActivationRefresh.shouldRefresh(windowOpen: false, visible: false))
    }

    /// Opening activates the app and un-occludes the window in the same turn: one pass, not two.
    func testActivationRightAfterAPassIsTheSameEvent() {
        XCTAssertFalse(ActivationRefresh.shouldRefresh(windowOpen: true, visible: true, secondsSinceLastPass: 0.2))
        XCTAssertTrue(ActivationRefresh.shouldRefresh(windowOpen: true, visible: true,
                                                      secondsSinceLastPass: ActivationRefresh.minimumGap))
        XCTAssertTrue(ActivationRefresh.shouldRefresh(windowOpen: true, visible: true, secondsSinceLastPass: 90))
        XCTAssertTrue(ActivationRefresh.shouldRefresh(windowOpen: true, visible: true, secondsSinceLastPass: nil), "never read yet")
    }
}
