import Accelerate
import XCTest
@testable import OxCleanCore

final class SpectrumTests: XCTestCase {
    private static let bins = FeatureConfig.bins
    private static let hop = FeatureConfig.frameShift
    private static let frame = FeatureConfig.frameLength

    private func signal(_ n: Int) -> [Float] {
        (0..<n).map { Float(sin(Double($0) * 0.03) * 8000 + Double($0 % 97)) }
    }

    // MARK: oracle: torch.stft (center=False, non-periodic Hamming 1920, hop 384, one-sided)

    func testSTFTMatchesTorch() throws {
        let x = try Fixture.floats("stft_clip.f32").map { $0 * FeatureConfig.scale }
        let ref = try Fixture.floats("stft_ref.f32")  // [50, 961, 2]
        let s = try Spectrum().stft(scaled: x)
        XCTAssertEqual(s.frames, 50)
        XCTAssertEqual(s.re.count, 50 * Self.bins)
        XCTAssertEqual(s.im.count, 50 * Self.bins)
        guard s.re.count == 50 * Self.bins, s.im.count == s.re.count else { return }
        let peak = ref.map { abs($0) }.max()!
        let got = zip(s.re, s.im).flatMap { [$0, $1] }
        let rel = Fixture.maxAbsDiff(got, ref) / peak
        print("stft max abs diff vs torch, relative to peak: \(rel)")
        XCTAssertLessThan(rel, 1e-4)
        // DC and Nyquist are real in a real signal's one-sided spectrum.
        for f in 0..<50 { XCTAssertEqual(s.im[f * Self.bins], 0); XCTAssertEqual(s.im[f * Self.bins + 960], 0) }
    }

    func testVDSPHasA1920PointRealDFTInBothDirections() {
        // Probe from the plan: if this fails on a new OS the fallback is a 1920 x 961 DFT matrix and cblas_sgemm.
        let fwd = Spectrum.makeSetup(.FORWARD), inv = Spectrum.makeSetup(.INVERSE)
        XCTAssertNotNil(fwd); XCTAssertNotNil(inv)
        if let fwd { vDSP_DFT_DestroySetup(fwd) }
        if let inv { vDSP_DFT_DestroySetup(inv) }
    }

    // MARK: inverse

    func testISTFTInvertsSTFTOverTheWholeSignal() throws {
        let x = (0..<192_000).map { Float(sin(Double($0) * 0.03) * 8000 + Double($0 % 97)) }
        let sp = try Spectrum(); let s = sp.stft(scaled: x)
        let y = sp.istft(re: s.re, im: s.im, frames: s.frames, length: x.count)
        XCTAssertEqual(y.count, x.count)
        guard y.count == x.count else { return }
        print("round trip max abs err: whole \(Fixture.maxAbsDiff(x, y))")
        XCTAssertLessThan(Fixture.maxAbsDiff(x, y), 0.05, "int16-range samples, float32 round trip")  // first and last 384 samples included
    }

    /// Where `sum w^2` is smallest (only one window covers the sample: w[0]^2 = 0.0064) the division amplifies float
    /// error ~156x. The edges must still invert, and are checked on their own.
    func testISTFTInvertsTheFirstAndLast384SamplesOnTheirOwn() throws {
        let x = signal(192_000), h = Self.hop
        let sp = try Spectrum(); let s = sp.stft(scaled: x)
        let y = sp.istft(re: s.re, im: s.im, frames: s.frames, length: x.count)
        guard y.count == x.count else { return XCTFail("length \(y.count)") }
        let head = Fixture.maxAbsDiff(Array(x[0..<h]), Array(y[0..<h]))
        let tail = Fixture.maxAbsDiff(Array(x[(x.count - h)...]), Array(y[(x.count - h)...]))
        print("round trip max abs err: first 384 \(head), last 384 \(tail)")
        XCTAssertLessThan(head, 0.05)
        XCTAssertLessThan(tail, 0.05)
    }

    func testEnvelopeNeverApproachesTorchsNearZeroGuard() {
        // torch.istft refuses a window overlap-add below 1e-11. With this window the minimum is w[0]^2 = 0.0064
        // (a sample covered by one frame only), so the guard is unreachable and the Swift istft needs no throwing path.
        let env = Spectrum.envelope(frames: 1)
        XCTAssertEqual(env.count, Self.frame)
        XCTAssertEqual(env.min()!, 0.0064, accuracy: 1e-5)
        XCTAssertGreaterThan(Spectrum.envelope(frames: 496).min()!, 1e-11)
    }

    func testAnAllOnesMaskIsTransparentAndAZeroMaskIsSilent() throws {
        let x = (0..<192_000).map { Float(sin(Double($0) * 0.05) * 5000) }
        let sp = try Spectrum(); let s = sp.stft(scaled: x)
        var re = s.re, im = s.im
        sp.apply(mask: [Float](repeating: 1, count: s.frames * 961), re: &re, im: &im)
        XCTAssertLessThan(Fixture.maxAbsDiff(sp.istft(re: re, im: im, frames: s.frames, length: x.count), x), 0.05)
        sp.apply(mask: [Float](repeating: 0, count: s.frames * 961), re: &re, im: &im)
        XCTAssertEqual(sp.istft(re: re, im: im, frames: s.frames, length: x.count).map(abs).max()!, 0, accuracy: 1e-6)
    }

    /// F3: a mask that scales only the real part leaves the imaginary part and so changes phase, not just level.
    /// A pure tone with a 0.5 mask must come back at exactly half amplitude, sample for sample.
    func testMaskScalesBothParts() throws {
        let x = (0..<48_000).map { Float(sin(Double($0) * 0.4) * 6000) }
        let sp = try Spectrum(); let s = sp.stft(scaled: x)
        var re = s.re, im = s.im
        sp.apply(mask: [Float](repeating: 0.5, count: s.frames * 961), re: &re, im: &im)
        let y = sp.istft(re: re, im: im, frames: s.frames, length: x.count)
        XCTAssertLessThan(Fixture.maxAbsDiff(y, x.map { $0 * 0.5 }), 0.05)
    }

    func testMaskIsPerBinPerFrame() throws {
        // A mask that keeps only frame 1 and bin 7: every other element is zero, that one is untouched.
        let sp = try Spectrum()
        var re = (0..<3 * 961).map { Float($0 + 1) }, im = (0..<3 * 961).map { Float(-$0 - 1) }
        var mask = [Float](repeating: 0, count: 3 * 961); mask[961 + 7] = 0.25
        let (r0, i0) = (re, im)
        sp.apply(mask: mask, re: &re, im: &im)
        for k in 0..<re.count {
            let want: Float = k == 961 + 7 ? 0.25 : 0
            XCTAssertEqual(re[k], r0[k] * want); XCTAssertEqual(im[k], i0[k] * want)
        }
    }

    // MARK: edge cases (torch semantics where torch defines them)

    func testASignalShorterThanOneFrameHasNoFrames() throws {
        // torch.stft raises for n < n_fft with center=False; here "no frames" is a value (Fbank does the same).
        let sp = try Spectrum()
        for n in [0, 1, 1919] {
            let s = sp.stft(scaled: [Float](repeating: 1, count: n))
            XCTAssertEqual(s.frames, 0); XCTAssertTrue(s.re.isEmpty); XCTAssertTrue(s.im.isEmpty)
        }
        // torch.istft raises on zero frames; here the result is `length` zeros.
        XCTAssertEqual(sp.istft(re: [], im: [], frames: 0, length: 700), [Float](repeating: 0, count: 700))
        XCTAssertEqual(sp.istft(re: [], im: [], frames: 0, length: 0), [])
    }

    func testExactlyOneFrameRoundTrips() throws {
        let x = signal(1920), sp = try Spectrum()
        let s = sp.stft(scaled: x)
        XCTAssertEqual(s.frames, 1)
        let y = sp.istft(re: s.re, im: s.im, frames: s.frames, length: x.count)
        XCTAssertEqual(y.count, 1920)
        guard y.count == 1920 else { return }
        let err = Fixture.maxAbsDiff(x, y)
        print("one frame round trip max abs err: \(err)")
        XCTAssertLessThan(err, 0.05)
        // Frame counts around the boundary.
        for (n, want) in [(1921, 1), (2303, 1), (2304, 2)] {
            XCTAssertEqual(sp.stft(scaled: signal(n)).frames, want, "n=\(n)")
        }
    }

    func testISTFTLengthMatchesTorchTruncationAndZeroPadding() throws {
        // 2303 samples -> one frame (1920 covered). torch.istft(length=n): the uncovered tail is zeros, a shorter length truncates.
        let x = signal(2303), sp = try Spectrum()
        let s = sp.stft(scaled: x)
        let full = sp.istft(re: s.re, im: s.im, frames: 1, length: 2303)
        XCTAssertEqual(full.count, 2303)
        XCTAssertLessThan(Fixture.maxAbsDiff(Array(full[0..<1920]), Array(x[0..<1920])), 0.05)
        XCTAssertTrue(full[1920...].allSatisfy { $0 == 0 }, "samples no frame covers are zero, as in torch")
        let cut = sp.istft(re: s.re, im: s.im, frames: 1, length: 1000)
        XCTAssertEqual(cut, Array(full[0..<1000]))
    }

    // MARK: concurrency and speed

    func testOneSpectrumIsSafeFromManyThreads() throws {
        let x = signal(96_000), sp = try Spectrum()
        let want = sp.stft(scaled: x), wantY = sp.istft(re: want.re, im: want.im, frames: want.frames, length: x.count)
        let lock = NSLock(); var bad = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let s = sp.stft(scaled: x)
            let y = sp.istft(re: s.re, im: s.im, frames: s.frames, length: x.count)
            if s.re != want.re || s.im != want.im || y != wantY { lock.lock(); bad += 1; lock.unlock() }
        }
        XCTAssertEqual(bad, 0, "calls on a shared Spectrum must not interfere")
    }

    func testTwentySecondWindowTime() throws {
        let x = signal(960_000), sp = try Spectrum()
        _ = sp.stft(scaled: x)  // warm up
        let t0 = Date()
        let s = sp.stft(scaled: x)
        let t1 = Date()
        let y = sp.istft(re: s.re, im: s.im, frames: s.frames, length: x.count)
        let t2 = Date()
        XCTAssertEqual(s.frames, 2496)
        XCTAssertEqual(y.count, x.count)
        let ms = t2.timeIntervalSince(t0) * 1000
        print("spectrum 20 s window: stft \(t1.timeIntervalSince(t0) * 1000) ms, istft \(t2.timeIntervalSince(t1) * 1000) ms, total \(ms) ms")
        #if !DEBUG
        XCTAssertLessThan(ms, 34, "STFT + iSTFT of one 20 s window must be well under the model's 68 ms")
        #endif
    }
}
