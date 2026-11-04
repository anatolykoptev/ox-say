import Foundation

/// Cuts a mono 48 kHz clip into the fixed 20 s windows the Core ML model takes, and splices the per-window outputs back
/// into exactly `sampleCount` samples. Pure value maths: no model, no I/O, no whole-clip buffer.
///
/// Rules (controller decision 2, measured in the 20 s window study):
/// - **Long clip (`n > window`).** Windows start at `0, stride, 2 * stride, ...` while `start + window < n`; the last
///   window is end-aligned (`start = n - window`). `n - window` is never also a regular start, so no start repeats.
/// - **Short clip (`n <= window`).** One window holding the clip's own audio tiled cyclically (`x[i % n]`), never zeros.
///   The output keeps `[0, n)`.
/// - **Seams.** Consecutive windows `k` and `k + 1` overlap on `[start(k+1), start(k) + window)`, at least
///   `window - stride` samples. The seam is the middle of that overlap (`seam(after:)`), with a linear crossfade of
///   `crossfade` samples centred on it: window `k` alone before it, window `k + 1` alone after it.
public struct Chunker: Equatable, Sendable {
    /// 20 s at 48 kHz: the model's fixed input.
    public static let window = 960_000
    /// 15 s between regular window starts.
    public static let stride = 720_000
    /// 50 ms at 48 kHz.
    public static let crossfade = 2_400

    public let sampleCount: Int

    public init(sampleCount: Int) {
        precondition(sampleCount >= 0, "sampleCount must not be negative")
        self.sampleCount = sampleCount
    }

    /// 0 for an empty clip, 1 for `n <= window`, else `1 + ceil((n - window) / stride)`.
    public var windowCount: Int {
        if sampleCount == 0 { return 0 }
        if sampleCount <= Self.window { return 1 }
        return 1 + (sampleCount - Self.window + Self.stride - 1) / Self.stride
    }

    /// Where window `k` starts in the clip. The last window of a long clip is end-aligned.
    public func start(of k: Int) -> Int {
        precondition(k >= 0 && k < windowCount, "window \(k) out of range")
        if sampleCount <= Self.window { return 0 }
        return k == windowCount - 1 ? sampleCount - Self.window : k * Self.stride
    }

    /// The centre of the crossfade between window `k` and `k + 1`: the middle of their overlap (rounded down).
    public func seam(after k: Int) -> Int {
        precondition(k >= 0 && k < windowCount - 1, "no seam after window \(k)")
        return (start(of: k + 1) + start(of: k) + Self.window) / 2
    }

    /// The `window` input samples of window `k`. `read` returns the clip's samples for a range inside `[0, sampleCount)`;
    /// a long clip's window is one read, a short clip's is one read of the whole clip, tiled.
    public func inputWindow(_ k: Int, read: (Range<Int>) throws -> [Float]) rethrows -> [Float] {
        let s = start(of: k)
        if sampleCount > Self.window { return try read(s..<s + Self.window) }
        var out = try read(0..<sampleCount)
        precondition(out.count == sampleCount, "read returned \(out.count) samples, expected \(sampleCount)")
        while out.count < Self.window {  // doubling keeps out.count a multiple of n until the last partial copy
            out += out.prefix(min(out.count, Self.window - out.count))
        }
        return out
    }

    /// `inputWindow(_:read:)` over a clip held in memory.
    public func inputWindow(_ k: Int, from samples: [Float]) -> [Float] {
        precondition(samples.count == sampleCount, "clip has \(samples.count) samples, chunker was built for \(sampleCount)")
        return inputWindow(k) { Array(samples[$0]) }
    }
}

/// Streaming splice of per-window outputs, in window order. Holds one crossfade tail (`crossfade` samples), never the set
/// of window outputs: each `push` returns the samples that became final, to be appended to the output file.
///
/// After window `k` (not the last) the emitted total is `seam(after: k) - crossfade / 2`, the start of the next fade;
/// after the last window it is `sampleCount`.
public struct WindowSplicer {
    /// `t` for sample `j` of the fade: `(j + 0.5) / crossfade`, so the weights of the two windows sum to exactly 1 and the
    /// ramp is symmetric about the seam.
    private static let ramp: [Float] = (0..<Chunker.crossfade).map { Float((Double($0) + 0.5) / Double(Chunker.crossfade)) }

    private let chunker: Chunker
    private var pushed = 0
    private var tail: [Float] = []
    public private(set) var emittedCount = 0

    public init(chunker: Chunker) { self.chunker = chunker }

    public var isComplete: Bool { pushed == chunker.windowCount }

    /// Adds window `windowIndex = number of earlier pushes`; `window` is the model's output for that window
    /// (`Chunker.window` samples). Returns the newly final output samples.
    public mutating func push(_ window: [Float]) -> [Float] {
        precondition(!isComplete, "all \(chunker.windowCount) windows were already pushed")
        precondition(window.count == Chunker.window, "window output has \(window.count) samples, expected \(Chunker.window)")
        let k = pushed, s = chunker.start(of: k), x = Chunker.crossfade
        var out: [Float] = []
        var cursor = 0  // index into `window` of the next sample to emit
        if k > 0 {
            let fadeStart = chunker.seam(after: k - 1) - x / 2 - s
            out.reserveCapacity(Chunker.window)
            for j in 0..<x {
                let a = tail[j], b = window[fadeStart + j]
                out.append(a + Self.ramp[j] * (b - a))  // a + t(b - a) is exactly a where a == b
            }
            cursor = fadeStart + x
        }
        let end: Int
        if k == chunker.windowCount - 1 {
            end = chunker.sampleCount - s
            tail = []
        } else {
            end = chunker.seam(after: k) - x / 2 - s
            tail = Array(window[end..<end + x])
        }
        out += window[cursor..<end]
        pushed += 1
        emittedCount += out.count
        return out
    }
}
