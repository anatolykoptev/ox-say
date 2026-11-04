import XCTest
@testable import OxCleanCore

final class FbankTests: XCTestCase {
    // MARK: oracle: torchaudio, dither 0

    func testFeaturesMatchTorchaudioOnAOneSecondClip() throws {
        let clip = try Fixture.floats("clip1s.f32").map { $0 * FeatureConfig.scale }
        let want = try Fixture.floats("feat1s.f32")
        let got = Fbank().features(scaled: clip)
        XCTAssertEqual(got.count, 121 * 180)
        guard got.count == want.count else { return }
        print("fbank max abs diff vs torchaudio: \(Fixture.maxAbsDiff(got, want))")
        XCTAssertLessThan(Fixture.maxAbsDiff(got, want), 2e-3, "log-mel and deltas, float32 vDSP against torch")
    }

    func testFrameCountIsSnipEdges() {
        XCTAssertEqual(Fbank().features(scaled: [Float](repeating: 1, count: 192_000)).count, 496 * 180)
        XCTAssertEqual(Fbank().features(scaled: [Float](repeating: 1, count: 1919)).count, 0)
        XCTAssertEqual(Fbank().features(scaled: [Float](repeating: 1, count: 1920)).count, 180)
    }

    func testSilenceIsFiniteAndDeterministic() {
        let zeros = [Float](repeating: 0, count: 192_000)
        let a = Fbank().features(scaled: zeros)
        XCTAssertTrue(a.allSatisfy { $0.isFinite })
        XCTAssertEqual(a, Fbank().features(scaled: zeros))
    }

    // MARK: dither (its own step)

    private func tone(_ n: Int) -> [Float] { (0..<n).map { 8000 * sin(Float($0) * 0.05) } }

    func testNoneIsBitIdenticalToDefault() {
        let x = tone(48_000)
        XCTAssertEqual(Fbank(dither: .none).features(scaled: x), Fbank().features(scaled: x))
    }

    func testSeededIsDeterministicAndSeedsDiffer() {
        let x = tone(48_000)
        let a = Fbank(dither: .seeded(7)).features(scaled: x)
        XCTAssertEqual(a, Fbank(dither: .seeded(7)).features(scaled: x))
        XCTAssertNotEqual(a, Fbank(dither: .seeded(8)).features(scaled: x))
        XCTAssertNotEqual(a, Fbank().features(scaled: x))
    }

    func testGeneratorMatchesIndependentPythonImplementation() throws {
        let want = try Fixture.floats("noise_golden.f32")
        var g1 = GaussianNoise(seed: 1), g2 = GaussianNoise(seed: 20261103)
        let got = (0..<64).map { _ in g1.next() } + (0..<64).map { _ in g2.next() }
        XCTAssertLessThan(Fixture.maxAbsDiff(got, want), 1e-5, "SplitMix64 + Box-Muller must not drift")
    }

    /// The batched fill used by the frame loop draws the same sequence as `next()`, including an odd count (spare).
    func testBatchedFillMatchesSingleDraws() {
        var a = GaussianNoise(seed: 11), b = GaussianNoise(seed: 11)
        var scratch = [Double](repeating: 0, count: 2 * 1921)
        for count in [1920, 7, 1, 1920] {
            var x = [Float](repeating: 0, count: count)
            x.withUnsafeMutableBufferPointer { p in scratch.withUnsafeMutableBufferPointer { a.add(to: p.baseAddress!, count: count, scratch: $0.baseAddress!) } }
            let want = (0..<count).map { _ in b.next() }
            XCTAssertLessThan(Fixture.maxAbsDiff(x, want), 1e-5, "count \(count)")
        }
    }

    /// Silent input: the conditioned frame is the noise minus its own mean. Over 3.84M samples the standard error of
    /// the mean is 1/sqrt(N) = 5.1e-4 and of the std 1/sqrt(2N) = 3.6e-4, so 3e-3 is about 6 sigma: a flake needs a
    /// 1-in-10^8 draw, while a wrong sigma (e.g. 0.5 or 2) or a biased generator misses by far more.
    func testNoiseIsZeroMeanUnitSigmaOverLongSilence() {
        let frames = 2000
        let n = FeatureConfig.frameLength + (frames - 1) * FeatureConfig.frameShift
        let f = Fbank(dither: .seeded(42)).conditionedFrames(scaled: [Float](repeating: 0, count: n))
        XCTAssertEqual(f.count, frames * FeatureConfig.frameLength)
        guard f.count == frames * FeatureConfig.frameLength else { return }
        let mean = f.reduce(0.0) { $0 + Double($1) } / Double(f.count)
        // DC removal shrinks the variance by (1 - 1/1920); compensate so the bound stays 6 sigma.
        let varr = f.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(f.count)
        let sigma = (varr * 1920.0 / 1919.0).squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 3e-3)
        XCTAssertEqual(sigma, 1.0, accuracy: 3e-3)
    }

    /// Dither goes in BEFORE DC removal (the torchaudio order), so every frame has zero mean afterwards. Applied after
    /// DC removal the frame mean would be N(0, 1/sqrt(1920)) = 0.023, 20x over this bound.
    func testDitherIsAppliedBeforeDcRemoval() {
        let x = [Float](repeating: 1000, count: 1920 + 50 * 384)
        let f = Fbank(dither: .seeded(3)).conditionedFrames(scaled: x)
        let L = FeatureConfig.frameLength
        XCTAssertEqual(f.count, 51 * L)
        guard f.count == 51 * L else { return }
        for fr in 0..<51 {
            let m = f[fr * L..<(fr + 1) * L].reduce(0.0) { $0 + Double($1) } / Double(L)
            XCTAssertEqual(m, 0, accuracy: 1e-3, "frame \(fr)")
        }
        XCTAssertGreaterThan(f[0..<L].map { abs($0) }.max()!, 0.5, "noise present, not just zeros")
    }

    /// Frames get independent noise: frame 0 and frame 1 of a silent input are not equal and not correlated
    /// (r has std 1/sqrt(1920) = 0.023; 0.1 is 4.3 sigma). One shared noise vector would give r = 1.
    func testEveryFrameGetsIndependentNoise() {
        let L = FeatureConfig.frameLength
        let f = Fbank(dither: .seeded(5)).conditionedFrames(scaled: [Float](repeating: 0, count: L + 4 * 384))
        XCTAssertEqual(f.count, 5 * L)
        guard f.count == 5 * L else { return }
        let a = Array(f[0..<L]), b = Array(f[L..<2 * L])
        XCTAssertNotEqual(a, b)
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<L {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
        }
        XCTAssertLessThan(abs(dot / (na * nb).squareRoot()), 0.1)
    }

    /// A longer input gives the same noise to the frames it shares with a shorter one (one stream, drawn in frame order).
    func testNoisePrefixIsStableAcrossLengths() {
        let short = Fbank(dither: .seeded(9)).conditionedFrames(scaled: [Float](repeating: 0, count: 1920 + 3 * 384))
        let long = Fbank(dither: .seeded(9)).conditionedFrames(scaled: [Float](repeating: 0, count: 1920 + 9 * 384))
        XCTAssertEqual(short.count, 4 * 1920)
        guard long.count >= short.count else { return XCTFail("long shorter than short") }
        XCTAssertEqual(Array(long[0..<short.count]), short)
    }

    // MARK: speed

    /// A 20 s window is one Core ML call (68 ms on M5 Pro); features must be a small fraction of that. The bound is
    /// loose on purpose (suite runs niced under a lock); it exists to catch an accidental per-frame allocation or O(n^2).
    func testTwentySecondWindowIsFast() {
        let x = tone(960_000)
        let t0 = Date()
        let out = Fbank(dither: .seeded(1)).features(scaled: x)
        let dt = Date().timeIntervalSince(t0)
        print("fbank 20 s window: \(dt * 1000) ms")
        let t1 = Date()
        _ = Fbank().features(scaled: x)
        print("fbank 20 s window, no dither: \(Date().timeIntervalSince(t1) * 1000) ms")
        XCTAssertEqual(out.count, 2496 * 180)
        XCTAssertLessThan(dt, 1.0)
    }
}
