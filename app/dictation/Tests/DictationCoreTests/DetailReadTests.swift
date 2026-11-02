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
}
