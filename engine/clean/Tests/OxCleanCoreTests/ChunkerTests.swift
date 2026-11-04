import XCTest
@testable import OxCleanCore

/// Task 6: the 20 s / 15 s chunker with end-aligned last window, tiled short clips and 50 ms crossfades.
/// The oracle (`testdata/chunker_ref.json`, made by `ref_chunker.py` from the spike's `reference.windowed20`) shares no code
/// with `Chunker.swift`.
final class ChunkerTests: XCTestCase {
    private let W = Chunker.window, S = Chunker.stride, X = Chunker.crossfade

    /// Lengths around every rule boundary (the brief's list, plus 2W and W + 2S).
    private var boundaryLengths: [Int] {
        [1, 2399, W - 1, W, W + 1, W + S - 1, W + S, W + S + 1, 2 * W, W + 2 * S, 3 * W + 17]
    }

    /// The oracle's deterministic input, regenerated bit for bit.
    private func oracleSample(_ i: Int) -> Float { Float((i * 7919) % 10007) / Float(10007) - 0.5 }

    /// Runs the whole pipeline the way Task 7 will: window by window, nothing held but one window and the splicer's tail.
    /// `enhance(k, window)` plays the network. `visit` receives each emitted chunk with its global offset.
    private func run(n: Int, source: (Range<Int>) -> [Float], enhance: (Int, [Float]) -> [Float],
                     visit: (Int, [Float]) -> Void) {
        let c = Chunker(sampleCount: n)
        var splicer = WindowSplicer(chunker: c)
        var offset = 0
        for k in 0..<c.windowCount {
            let out = splicer.push(enhance(k, c.inputWindow(k, read: source)))
            visit(offset, out)
            offset += out.count
        }
        XCTAssertEqual(offset, n, "n = \(n): output length")
        XCTAssertTrue(splicer.isComplete, "n = \(n)")
    }

    private func assemble(_ x: [Float], enhance: (Int, [Float]) -> [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(x.count)
        run(n: x.count, source: { Array(x[$0]) }, enhance: enhance) { _, chunk in out += chunk }
        return out
    }

    // MARK: oracle

    private struct Oracle: Decodable {
        struct Case: Decodable { let n: Int; let starts: [Int]; let mids: [Int]; let samples: [[Double]] }
        let window: Int, stride: Int, crossfade: Int
        let cases: [Case]
    }

    func testMatchesTheSpikesPythonChunker() throws {
        let data = try Data(contentsOf: Fixture.dir.appendingPathComponent("chunker_ref.json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: data)
        XCTAssertEqual([oracle.window, oracle.stride, oracle.crossfade], [W, S, X])
        XCTAssertGreaterThanOrEqual(oracle.cases.count, 12)
        for oc in oracle.cases {
            let c = Chunker(sampleCount: oc.n)
            XCTAssertEqual(c.windowCount, oc.starts.count, "n = \(oc.n): window count")
            XCTAssertEqual((0..<c.windowCount).map { c.start(of: $0) }, oc.starts, "n = \(oc.n): starts")
            XCTAssertEqual((0..<max(0, c.windowCount - 1)).map { c.seam(after: $0) }, oc.mids, "n = \(oc.n): seam centres")
            // The oracle's enhancer: window k returns its input x (k + 1).
            var next = 0, worst: Float = 0, worstAt = -1
            let samples = oc.samples
            run(n: oc.n, source: { r in r.map { self.oracleSample($0) } },
                enhance: { k, w in w.map { $0 * Float(k + 1) } }) { offset, chunk in
                while next < samples.count, Int(samples[next][0]) < offset + chunk.count {
                    let i = Int(samples[next][0]), want = Float(samples[next][1])
                    let err = abs(chunk[i - offset] - want) / max(1, abs(want))
                    if err > worst { worst = err; worstAt = i }
                    next += 1
                }
            }
            XCTAssertEqual(next, samples.count, "n = \(oc.n): every oracle sample was reached")
            XCTAssertLessThan(worst, 2e-6, "n = \(oc.n): worst relative error \(worst) at sample \(worstAt)")
        }
    }

    // MARK: rules

    func testWindowStartsAndNoDuplicateEndAlignedWindow() {
        XCTAssertEqual(Chunker(sampleCount: W).windowCount, 1)
        XCTAssertEqual(Chunker(sampleCount: W + 1).windowCount, 2)
        XCTAssertEqual(Chunker(sampleCount: W + S).windowCount, 2)
        XCTAssertEqual(Chunker(sampleCount: W + S + 1).windowCount, 3)
        // n - W lands exactly on a regular start: one window there, not two.
        for n in [W + S, W + 2 * S, W + 5 * S] {
            let c = Chunker(sampleCount: n)
            let starts = (0..<c.windowCount).map { c.start(of: $0) }
            XCTAssertEqual(starts, Array(stride(from: 0, through: n - W, by: S)), "n = \(n)")
        }
        var rng = SystemRandomNumberGenerator()
        for n in boundaryLengths + (0..<300).map({ _ in Int.random(in: 1...(40 * W), using: &rng) }) {
            let c = Chunker(sampleCount: n)
            let starts = (0..<c.windowCount).map { c.start(of: $0) }
            XCTAssertEqual(Set(starts).count, starts.count, "n = \(n): duplicate start in \(starts)")
            XCTAssertEqual(starts, starts.sorted(), "n = \(n)")
            XCTAssertEqual(starts.last, max(0, n - W), "n = \(n): last window is end-aligned")
        }
    }

    func testShortClipInputIsTiledNeverZeros() {
        for n in [1, 2, 2399, 100_000, W / 2 + 1, W - 1] {
            let x = (0..<n).map { Float($0 + 1) }            // never 0, so a zero in the window is a fill bug
            let c = Chunker(sampleCount: n)
            XCTAssertEqual(c.windowCount, 1, "n = \(n)")
            let w = c.inputWindow(0, from: x)
            XCTAssertEqual(w.count, W, "n = \(n)")
            XCTAssertNil(w.firstIndex(of: 0), "n = \(n): zero fill")
            XCTAssertEqual(w.enumerated().first { $0.element != x[$0.offset % n] }?.offset, nil, "n = \(n): not x[i % n]")
        }
        // A clip of exactly one window is used as is.
        let exact = (0..<W).map { Float($0) }
        XCTAssertEqual(Chunker(sampleCount: W).inputWindow(0, from: exact), exact)
    }

    func testLongClipWindowsAreDirectSlices() {
        let n = 2 * W + 12_345
        let x = (0..<n).map { Float($0 % 9973) }
        let c = Chunker(sampleCount: n)
        for k in 0..<c.windowCount {
            let s = c.start(of: k)
            XCTAssertEqual(c.inputWindow(k, from: x), Array(x[s..<s + W]), "window \(k)")
        }
        XCTAssertEqual(c.start(of: c.windowCount - 1) + W, n, "last window ends exactly at the clip end")
    }

    func testMinimumOverlapAndCrossfadeFitInsideBothWindows() {
        var rng = SystemRandomNumberGenerator()
        // Up to 2 h of 48 kHz audio: starts only, no signals.
        let candidates = boundaryLengths + [7200 * 48_000, 7200 * 48_000 - 1] + (0..<3000).map { _ in Int.random(in: 1...(7200 * 48_000), using: &rng) }
        for n in candidates where n > W {
            let c = Chunker(sampleCount: n)
            XCTAssertEqual(c.start(of: 0), 0)
            for k in 0..<(c.windowCount - 1) {
                let a = c.start(of: k), b = c.start(of: k + 1), m = c.seam(after: k)
                XCTAssertGreaterThanOrEqual(a + W - b, W - S, "n = \(n), seam \(k): overlap")
                XCTAssertEqual(m, (b + a + W) / 2, "n = \(n), seam \(k): middle of the overlap")
                XCTAssertGreaterThanOrEqual(m - X / 2, b, "n = \(n), seam \(k): fade starts inside window k+1")
                XCTAssertLessThanOrEqual(m - X / 2 + X, a + W, "n = \(n), seam \(k): fade ends inside window k")
            }
        }
    }

    // MARK: reassembly

    func testIdentityEnhancerReassemblesTheInputExactlyAtEveryBoundary() {
        for n in boundaryLengths {
            let x = (0..<n).map { Float($0 % 9973) }
            let y = assemble(x) { _, w in w }
            XCTAssertEqual(y.count, n, "n = \(n)")
            XCTAssertNil(y.firstIndex { $0.isNaN }, "n = \(n): NaN")
            XCTAssertTrue(y == x, "n = \(n): first difference at \(zip(y, x).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)")
        }
    }

    func testEverySeamIsALinearRampOfExactlyCrossfadeSamples() {
        let n = 3 * W + 17                                  // 4 windows, 3 seams
        let x = [Float](repeating: 1, count: n)
        let y = assemble(x) { k, w in w.map { $0 * Float(k + 1) } }
        let c = Chunker(sampleCount: n)
        XCTAssertEqual(c.windowCount, 4)
        var expected = [Float](repeating: 0, count: n)
        var level = 1                                       // window k owns [m(k-1) + X/2, m(k) - X/2)
        var cursor = 0
        for k in 0..<(c.windowCount - 1) {
            let f0 = c.seam(after: k) - X / 2
            for i in cursor..<f0 { expected[i] = Float(level) }
            for j in 0..<X { expected[f0 + j] = Float(level) + Float((Double(j) + 0.5) / Double(X)) }
            level += 1
            cursor = f0 + X
        }
        for i in cursor..<n { expected[i] = Float(level) }
        var worst: Float = 0, at = -1
        for i in 0..<n { let e = abs(y[i] - expected[i]); if e > worst { worst = e; at = i } }
        XCTAssertLessThan(worst, 1e-5, "largest deviation from a piecewise level / 2400-sample ramp: \(worst) at sample \(at)")
        for k in 0..<3 {
            let f0 = c.seam(after: k) - X / 2
            XCTAssertEqual(y[f0 - 1], Float(k + 1), "seam \(k): level before the ramp")
            XCTAssertEqual(y[f0 + X], Float(k + 2), "seam \(k): level after the ramp")
            XCTAssertEqual((y[f0 + X / 2 - 1] + y[f0 + X / 2]) / 2, Float(k) + 1.5, accuracy: 1e-5, "seam \(k): centred on the middle of the overlap")
        }
    }

    func testStreamingEmitsAsSoonAsFinalAndMatchesTheBatchAssembly() {
        let n = 3 * W + 17
        let x = (0..<n).map { oracleSample($0) }
        let enhance: (Int, [Float]) -> [Float] = { k, w in w.map { $0 * Float(k + 1) } }
        let c = Chunker(sampleCount: n)
        var splicer = WindowSplicer(chunker: c)
        var streamed: [Float] = []
        for k in 0..<c.windowCount {
            let out = splicer.push(enhance(k, c.inputWindow(k, from: x)))
            XCTAssertLessThanOrEqual(out.count, W, "push \(k) never holds back or releases more than one window")
            streamed += out
            // Everything up to the start of the next crossfade is final; nothing beyond it can be.
            let finalUpTo = k == c.windowCount - 1 ? n : c.seam(after: k) - X / 2
            XCTAssertEqual(splicer.emittedCount, finalUpTo, "after window \(k)")
            XCTAssertEqual(streamed.count, finalUpTo, "after window \(k)")
        }
        // Batch: the whole set of window outputs at once, weights summed over the full signal (the oracle's shape).
        var batch = [Double](repeating: 0, count: n)
        let starts = (0..<c.windowCount).map { c.start(of: $0) }
        for k in 0..<c.windowCount {
            let y = enhance(k, c.inputWindow(k, from: x))
            let lo = k == 0 ? 0 : c.seam(after: k - 1) - X / 2, hi = k == c.windowCount - 1 ? n : c.seam(after: k) + X / 2
            for g in lo..<hi {
                var w = 1.0
                if k > 0 { let j = g - lo; if j < X { w = (Double(j) + 0.5) / Double(X) } }
                if k < c.windowCount - 1 { let j = g - (c.seam(after: k) - X / 2); if j >= 0 { w = 1 - (Double(j) + 0.5) / Double(X) } }
                batch[g] += w * Double(y[g - starts[k]])
            }
        }
        var worst = 0.0
        for i in 0..<n { worst = max(worst, abs(Double(streamed[i]) - batch[i])) }
        XCTAssertLessThan(worst, 2e-5, "streaming vs batch")
    }
}
