import XCTest
@testable import DictationCore

/// The open meeting's detail is read one at a time per meeting, and the answer of a read that was given up is dropped.
final class DetailReadsTests: XCTestCase {
    /// Mutation: DetailReads.request, return a token even while one is in flight -> RED (a second read starts).
    func testOneReadPerMeetingIsInFlight() {
        var reads = DetailReads()
        let first = reads.request("a")
        XCTAssertNotNil(first)
        XCTAssertNil(reads.request("a"), "a second read of the same meeting waits for the first")
        XCTAssertNotNil(reads.request("b"), "another meeting reads at once")
    }

    /// A request that came while the read ran is not lost: the meeting is read once more when the first ends.
    /// Mutation: DetailReads.finish, never set `rerun` -> RED.
    func testARequestDuringARunIsReadOnceMoreAfterwards() throws {
        var reads = DetailReads()
        let t1 = try XCTUnwrap(reads.request("a"))
        XCTAssertNil(reads.request("a"))
        XCTAssertNil(reads.request("a"), "any number of requests make one more read")
        let done = reads.finish("a", token: t1)
        XCTAssertEqual(done, DetailReads.Outcome(apply: true, rerun: true))
        let t2 = try XCTUnwrap(reads.request("a"))
        XCTAssertEqual(reads.finish("a", token: t2), DetailReads.Outcome(apply: true, rerun: false))
        XCTAssertNotNil(reads.request("a"), "free again once the reads are done")
    }

    /// A read whose meeting was deleted (or whose window was reset) must not put the old answer back.
    /// Mutation: DetailReads.cancel, do nothing -> RED.
    func testTheAnswerOfACancelledReadIsDropped() throws {
        var reads = DetailReads()
        let old = try XCTUnwrap(reads.request("a"))
        reads.cancel("a")
        let fresh = try XCTUnwrap(reads.request("a"))
        XCTAssertEqual(reads.finish("a", token: old), DetailReads.Outcome(apply: false, rerun: false), "the stale answer arrives first")
        XCTAssertEqual(reads.finish("a", token: fresh), DetailReads.Outcome(apply: true, rerun: false))
    }

    func testAnAnswerForAMeetingNoRequestStartedIsDropped() {
        var reads = DetailReads()
        XCTAssertEqual(reads.finish("zzz", token: 7), DetailReads.Outcome(apply: false, rerun: false))
    }
}
