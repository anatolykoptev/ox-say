import Foundation
import XCTest
@testable import DictationCore

final class HostClockTests: XCTestCase {
    /// Apple Silicon ticks are 125/3 ns; a writer fed raw ticks would put a
    /// channel at 1/41 of its real time.
    /// Mutation: HostClock.nanos, drop the `numer` multiply -> RED.
    func testTicksBecomeNanosecondsThroughTheTimebase() {
        let apple = HostClock.Timebase(numer: 125, denom: 3)
        XCTAssertEqual(HostClock.nanos(fromHostTicks: 24_000_000, timebase: apple), 1_000_000_000)
        XCTAssertEqual(HostClock.nanos(fromHostTicks: 3, timebase: apple), 125)
        XCTAssertEqual(HostClock.nanos(fromHostTicks: 987_654, timebase: HostClock.Timebase(numer: 1, denom: 1)), 987_654)
    }

    func testALongUptimeDoesNotOverflow() {
        let apple = HostClock.Timebase(numer: 125, denom: 3)
        // ticks * 125 exceeds UInt64 while the result still fits.
        XCTAssertEqual(HostClock.nanos(fromHostTicks: 300_000_000_000_000_000, timebase: apple), 12_500_000_000_000_000_000)
    }

    /// A garbage mHostTime (or a hostile timebase) makes the result exceed 64 bits;
    /// the conversion saturates instead of trapping inside the audio callback.
    /// Mutation: HostClock.nanos, delete the `product.high >= denom` guard -> RED (trap).
    func testAResultBeyond64BitsSaturatesInsteadOfTrapping() {
        let wide = HostClock.Timebase(numer: UInt32.max, denom: 1)
        XCTAssertEqual(HostClock.nanos(fromHostTicks: UInt64.max, timebase: wide), UInt64.max)
        XCTAssertEqual(HostClock.nanos(fromHostTicks: UInt64.max, timebase: HostClock.Timebase(numer: 125, denom: 3)), UInt64.max)
    }

    func testTheMachineTimebaseIsUsable() {
        XCTAssertNotEqual(HostClock.timebase.denom, 0)
        XCTAssertGreaterThan(HostClock.nanos(fromHostTicks: 1_000_000), 0)
    }
}
