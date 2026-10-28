import Foundation

/// Appends one channel of a meeting to its file as raw signed 16-bit
/// little-endian mono at 16 kHz — the format the daemon reads (internal/meeting
/// audio.go). There is no header to repair and no segment to close: whatever
/// reached the file when the app died is the recording.
///
/// Both channels start at the same instant `t0`; a channel whose device starts
/// late, loses its input for a while (a tap rebuilt after the output device
/// changed) or drops buffers is padded with silence, so a sample's position in
/// the file is its time in the meeting, and a word's timestamp in one channel
/// means the same as in the other. The opposite error is corrected the same
/// way: a device clock that runs fast (tens of ppm over a 2–3 hour call),
/// overlapping or backwards timestamps, or a rebuilt tap whose first chunk
/// starts before what is already written all leave the channel AHEAD of the
/// clock, and the excess head of the chunk is dropped, so neither channel
/// drifts from the other.
///
/// Clock contract: `t0`, every `append(atNanos:)` and `finish(atNanos:)` are
/// host-time NANOSECONDS (`mach_absolute_time` ticks converted once, through
/// `HostClock.nanos(fromHostTicks:)`, by whoever feeds the writer). Mixing
/// raw ticks with nanoseconds shifts a channel by the timebase ratio
/// (125/3 on Apple Silicon).
///
/// Failure contract: a write that fails (a full disk) stops the channel — the
/// samples position does not advance, later appends are counted in
/// `failedWrites` and not written. The controller stops the recording and
/// warns the user on the first failure.
public final class PcmChannelWriter {
    public static let sampleRate = 16000
    /// A gap shorter than this is clock jitter, not lost audio.
    public static let gapTolerance = 1600 // 100 ms
    /// An overlap (a chunk stamped before the written position) at or below this is timestamp jitter, not duplicated
    /// audio, and is kept; above it the whole overlap is trimmed. 20 ms: host-time jitter of a real device is well under
    /// 2 ms (sigma). Measured with `scripts/overlap-jitter-sim.py`: with no allowance a -300 ppm clock at sigma 2 ms
    /// loses 283 ms of real audio in two hours; with 20 ms it loses none. A rebuilt tap's overlap with the old one is
    /// about one chunk (at most ~11-21 ms), which is INSIDE this allowance, so it is kept, not trimmed: the price is a
    /// splice glitch of up to ~20 ms per output switch. The file length stays right either way (`written` follows the
    /// clock); only an overlap past the allowance is cut.
    public static let overlapAllowance = 320 // 20 ms

    private let handle: FileHandle
    private let t0: UInt64
    private var written = 0
    private let lock = NSLock()
    private var failed = 0
    private var dropped = 0
    private var padded = 0

    /// Writes that failed; the controller stops and tells the user on the first.
    public var failedWrites: Int { lock.withLock { failed } }

    /// Samples cut off because the channel ran ahead of the clock (a head
    /// trimmed in `append`, an overshoot cut in `finish`): the controller logs
    /// it to show how the drift was handled.
    public var droppedSamples: Int { lock.withLock { dropped } }

    /// Samples of silence added for a late start, a lost stretch or the tail
    /// up to the end time.
    public var paddedSamples: Int { lock.withLock { padded } }

    /// `t0` is the meeting's start, in the same nanosecond clock `append` is given.
    public convenience init(url: URL, t0: UInt64) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try self.init(handle: FileHandle(forWritingTo: url), t0: t0)
    }

    init(handle: FileHandle, t0: UInt64) {
        self.handle = handle
        self.t0 = t0
    }

    /// Samples written so far, padding included: the channel's length.
    public var samples: Int { lock.withLock { written } }

    /// Appends `chunk`, recorded at `nanos` (the time of its first sample).
    public func append(_ chunk: [Float], atNanos nanos: UInt64) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard failed == 0 else { failed += 1; return }
        let expected = Self.samples(at: nanos, since: t0)
        var chunk = chunk
        if expected - written > Self.gapTolerance {
            pad(to: expected)
        } else if written - expected > Self.overlapAllowance {
            // The channel is ahead of the clock by more than `overlapAllowance`:
            // its head would land in time that is already written (a device
            // clock that runs fast, a long overlap). Keep the position equal to
            // the time. A smaller overlap is kept, so real speech is not shaved
            // by a noisy timestamp.
            let drop = min(written - expected, chunk.count)
            chunk.removeFirst(drop)
            dropped += drop
            if chunk.isEmpty { return }
        }
        guard failed == 0, write(Self.pcm16(chunk)) else { return }
        written += chunk.count
    }

    private static func samples(at nanos: UInt64, since t0: UInt64) -> Int {
        nanos > t0 ? Int(Double(nanos - t0) / 1e9 * Double(sampleRate)) : 0
    }

    /// Zeros up to `target` samples, a second at a time: a Mac that slept for
    /// hours must not allocate the whole gap at once.
    private func pad(to target: Int) {
        let second = Data(count: Self.sampleRate * 2)
        while written < target {
            let n = min(Self.sampleRate, target - written)
            guard write(n == Self.sampleRate ? second : Data(count: n * 2)) else { return }
            written += n
            padded += n
        }
    }

    /// A failed write (a full disk) is counted, not thrown from the audio thread:
    /// `failedWrites` > 0 tells the controller the recording is incomplete.
    private func write(_ data: Data) -> Bool {
        do { try handle.write(contentsOf: data); return true } catch { failed += 1; return false }
    }

    /// Ends the channel at `nanos`: silence up to it, or — when the channel ran
    /// ahead by more than the jitter tolerance — the overshoot cut off. A tail
    /// within the tolerance is real audio of the last buffer and stays, so both
    /// channels end within `gapTolerance` of each other.
    public func finish(atNanos nanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if failed == 0 {
            let expected = Self.samples(at: nanos, since: t0)
            pad(to: expected)
            if failed == 0, written - expected > Self.gapTolerance {
                do {
                    try handle.truncate(atOffset: UInt64(expected) * 2)
                    dropped += written - expected
                    written = expected
                } catch { failed += 1 }
            }
        }
        try? handle.close()
    }

    static func pcm16(_ chunk: [Float]) -> Data {
        var out = Data(count: chunk.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, f) in chunk.enumerated() {
                p[i] = Int16(littleEndian: f.isNaN ? 0 : Int16(max(-1, min(1, f)) * 32767))
            }
        }
        return out
    }
}
