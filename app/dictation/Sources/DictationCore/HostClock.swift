import Foundation

/// The one place host-time ticks become nanoseconds. Core Audio stamps buffers
/// in `mach_absolute_time` ticks, whose length is the CPU's business (41.67 ns
/// on Apple Silicon, 1 ns on Intel); `PcmChannelWriter` takes nanoseconds, so
/// the recorder converts every timestamp — and the meeting's t0 — through here.
public enum HostClock {
    public struct Timebase: Equatable {
        public var numer: UInt32
        public var denom: UInt32
        public init(numer: UInt32, denom: UInt32) {
            self.numer = numer
            self.denom = denom
        }
    }

    /// This machine's tick length, read once.
    public static let timebase: Timebase = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Timebase(numer: info.numer, denom: info.denom)
    }()

    /// `ticks` × numer / denom, in 128-bit arithmetic so a long uptime cannot overflow.
    public static func nanos(fromHostTicks ticks: UInt64, timebase: Timebase = HostClock.timebase) -> UInt64 {
        guard timebase.denom != 0 else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }
}
