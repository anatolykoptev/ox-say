import XCTest
@testable import DictationCore

/// Which selected meetings a polling pass reads the detail of: a restored selection was never read, a row that
/// moved on is read again, and a failed read waits for the user's Retry.
final class DetailReadTests: XCTestCase {
    private let row = MeetingInfo(id: "m", title: "Standup", status: .done)

    /// F1 — a quit on a meeting, relaunch, open: the restored selection fires no `onChange`, so the pass reads it.
    /// Mutation: MainWindowSource.refreshSelectedDetail back to `guard let shown` -> RED (the wiring test names it).
    func testANeverReadSelectionIsRead() {
        XCTAssertTrue(DetailRead.needed(row: row, shown: nil, failed: false))
    }

    /// F2 — a failed read with nothing shown is the Retry state: a polling pass must not retry behind it.
    /// Mutation: DetailRead.needed, `return !failed` -> `return true` -> RED.
    func testAFailedReadWithNothingShownIsNotRetried() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: true))
    }

    /// As before: the list moving on (processing finished, the notes arrived, the title changed) reads it again,
    /// behind an error sentence or not — a failed reread keeps the shown detail, which is what is compared.
    /// Mutation: DetailRead.needed, `shown.status != row.status` -> `false` -> RED.
    func testARowThatMovedOnIsReadAgain() {
        let stale = MeetingInfo(id: "m", title: "Standup", status: .transcribing)
        XCTAssertTrue(DetailRead.needed(row: row, shown: stale, failed: false))
        XCTAssertTrue(DetailRead.needed(row: row, shown: stale, failed: true), "a stale detail behind an error is still reread")
        let renamed = MeetingInfo(id: "m", title: "Sync", status: .done)
        XCTAssertTrue(DetailRead.needed(row: row, shown: renamed, failed: false))
    }

    /// A detail in step with its row is not read again.
    /// Mutation: DetailRead.needed, the `shown` guard returning `!failed` -> `true` unconditionally -> RED.
    func testADetailInStepWithItsRowIsNotReadAgain() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: row, failed: false))
        XCTAssertFalse(DetailRead.needed(row: row, shown: row, failed: true))
    }

    // MARK: #401 — a refresh landing in the first read

    /// The first read of a meeting is in flight (nothing shown yet): a refresh pass must not queue a second one.
    /// Mutation: DetailRead.needed, `return !failed && !loading` -> `return !failed` -> RED.
    func testAFirstReadInFlightIsNotQueuedAgain() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: false, loading: true))
    }

    /// The restored meeting (a selection that fired no `onChange`) still loads once: nothing shown, nothing loading.
    func testARestoredSelectionStillLoadsOnce() {
        XCTAssertTrue(DetailRead.needed(row: row, shown: nil, failed: false, loading: false))
    }

    /// The normal click path: `onChange` starts the read, then a pass runs while it is in flight, then it lands.
    func testAClickedMeetingIsReadOnceAcrossARefreshDuringItsRead() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: false, loading: true), "pass during the read")
        XCTAssertFalse(DetailRead.needed(row: row, shown: row, failed: false, loading: false), "after it landed")
    }

    /// A first read that fails while a pass lands must not flicker into a silent retry; after it settled the Retry
    /// state waits for the user.
    func testRetryStateDoesNotFlickerWhileTheFirstReadFails() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: true, loading: true))
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: true, loading: false))
    }

    /// Failed, then the user's Retry is in flight (the error is cleared when it starts, `loading` is set): a pass
    /// during it queues nothing. When that retry fails too, the error stands and the pass stays quiet.
    func testTheUsersRetryInFlightIsNotDoubled() {
        XCTAssertFalse(DetailRead.needed(row: row, shown: nil, failed: false, loading: true))
    }

    /// A shown detail whose row moved on is reread whether or not a read is loading: the in-flight read may predate
    /// the move, and `DetailReads` folds the extra request into one rerun, so it is bounded.
    func testAMovedOnRowIsStillReadWhileAReadIsLoading() {
        let stale = MeetingInfo(id: "m", title: "Standup", status: .transcribing)
        XCTAssertTrue(DetailRead.needed(row: row, shown: stale, failed: false, loading: true))
    }

    /// The pair the source relies on: the extra request during a read is folded, never a second parallel read.
    func testARequestDuringAReadFoldsIntoOneRerun() throws {
        var reads = DetailReads()
        let token = try XCTUnwrap(reads.request("m"))
        XCTAssertNil(reads.request("m"))
        XCTAssertEqual(reads.finish("m", token: token), DetailReads.Outcome(apply: true, rerun: true))
    }
}
