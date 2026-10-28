import XCTest
@testable import DictationCore

/// #129 — a `paste settled` line shares an id with the timing line of the
/// dictation whose paste it settles. The paste settles up to 3 s later (or at
/// the next deliver), so without an id two quick dictations interleave.
final class PasteLogCorrelationTests: XCTestCase {
    private func timing(delivery: Delivery?) -> DictationTiming {
        DictationTiming(recordedSeconds: 1, releaseToTextMs: 900,
                        stats: TranscriberStats(path: .stream), outcome: .delivered, delivery: delivery)
    }

    /// The id is appended last, so every earlier key stays byte-identical.
    /// Mutation: drop the id from DictationTiming.line(deliveryID:) -> RED.
    func testTheTimingLineCarriesTheDeliveryIDLast() {
        let t = timing(delivery: .paste)
        XCTAssertEqual(t.line(deliveryID: 7), t.line + " id=7")
    }

    /// A dictation that delivered nothing has no delivery to point at.
    func testNoDeliveryNoID() {
        let t = timing(delivery: nil)
        XCTAssertEqual(t.line(deliveryID: 7), t.line)
    }

    /// The settled line names the same id.
    /// Mutation: PasteSettledLog.text prints a constant id -> RED.
    func testTheSettledLineNamesTheSameID() {
        XCTAssertEqual(PasteSettledLog.text(id: 7, read: true), "paste settled id=7 read=yes")
        XCTAssertEqual(PasteSettledLog.text(id: 8, read: false), "paste settled id=8 read=no")
        let t = timing(delivery: .paste)
        XCTAssertTrue(t.line(deliveryID: 7).hasSuffix(" id=7"))
    }
}
