import XCTest
@testable import DictationCore

/// A notification opened before its handler is wired (a launch by clicking an old reminder, before the controller
/// exists) is not lost: it is held and delivered once, when the handler arrives.
final class LatchedSignalTests: XCTestCase {
    /// Mutation: LatchedSignal.setHandler, delete the `if pending { … }` flush -> RED.
    @MainActor
    func testAnOpenBeforeWiringIsDeliveredOnceAfterWiringAndNeverTwice() {
        let signal = LatchedSignal()
        signal.fire()
        signal.fire()   // two opens before wiring are still one pending acknowledgement
        var delivered = 0
        signal.setHandler { delivered += 1 }
        XCTAssertEqual(delivered, 1, "delivered when the handler is assigned")
        signal.setHandler { delivered += 10 }   // re-wiring must not replay it
        XCTAssertEqual(delivered, 1, "never twice")
    }

    /// Mutation: LatchedSignal.fire, drop the `else { pending = true }` -> RED.
    @MainActor
    func testAnOpenAfterWiringIsDeliveredAtOnce() {
        let signal = LatchedSignal()
        var delivered = 0
        signal.setHandler { delivered += 1 }
        XCTAssertEqual(delivered, 0, "nothing pending, nothing delivered")
        signal.fire()
        XCTAssertEqual(delivered, 1)
        signal.fire()
        XCTAssertEqual(delivered, 2, "each later open is its own delivery")
    }
}
