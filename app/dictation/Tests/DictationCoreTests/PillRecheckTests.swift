import XCTest
@testable import DictationCore

/// #306.2 — a pill shown within 250 ms of a lock has its window-server check skipped (the screen is locked);
/// after the unlock or wake that one skipped check is armed again, once, for the same show only.
final class PillRecheckTests: XCTestCase {
    /// Mutation: PillRecheck.resume returns false whatever is pending -> RED.
    func testAnUnlockRearmsTheCheckThatTheLockSkipped() {
        var recheck = PillRecheck()
        recheck.skipped(show: 4)
        XCTAssertTrue(recheck.resume(show: 4, wantsVisible: true))
    }

    /// Only once: a second unlock/wake does not check again.
    func testTheRearmFiresOnce() {
        var recheck = PillRecheck()
        recheck.skipped(show: 4)
        XCTAssertTrue(recheck.resume(show: 4, wantsVisible: true))
        XCTAssertFalse(recheck.resume(show: 4, wantsVisible: true))
    }

    /// A newer show has its own check; a hidden pill needs none.
    /// Mutation: drop the `show == pending` comparison in PillRecheck.resume -> RED.
    func testAStaleShowOrAHiddenPillIsNotRechecked() {
        var newer = PillRecheck()
        newer.skipped(show: 4)
        XCTAssertFalse(newer.resume(show: 5, wantsVisible: true))
        var hidden = PillRecheck()
        hidden.skipped(show: 4)
        XCTAssertFalse(hidden.resume(show: 4, wantsVisible: false))
    }

    /// Nothing was skipped: an unlock checks nothing.
    func testNothingSkippedMeansNothingToRecheck() {
        var recheck = PillRecheck()
        XCTAssertFalse(recheck.resume(show: 1, wantsVisible: true))
    }
}
