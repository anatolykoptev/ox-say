import XCTest
@testable import OxCleanCore

final class CleanerTests: XCTestCase {
    // MARK: transparency and seams

    func testOutputHasTheInputLengthAndAnIdentityMaskIsTransparent() throws {
        // 48,000 is a short clip (tiled), 960,000 exactly one window, 1,700,001 three windows with two seams.
        for n in [48_000, 960_000, 1_700_001] {
            let x = CleanFixture.noiseAndTone(frames: n)
            let y = try CleanFixture.clean(x, model: Constant(v: 1))
            XCTAssertEqual(y.count, n)
            guard y.count == n else { continue }
            XCTAssertGreaterThan(Fixture.siSdr(y, x), 60, "n = \(n)")
        }
    }

    func testAHalfMaskHalvesTheAmplitudeEverywhereIncludingSeams() throws {
        let n = 1_700_001
        let x = CleanFixture.noiseAndTone(frames: n)
        let y = try CleanFixture.clean(x, model: Constant(v: 0.5))
        XCTAssertEqual(y.count, n)
        guard y.count == n else { return }
        XCTAssertLessThan(Fixture.maxAbsDiff(y, x.map { $0 * 0.5 }), 1e-3)
    }

    // MARK: scaling

    func testTheWaveformIsScaledBy32768BeforeTheFeatures() throws {
        // One full window, so the features the model sees are exactly Fbank(dither: seeded) of the scaled clip.
        final class Spy: MaskPredicting {
            var first: [Float]?
            func mask(features: [Float], frames: Int) throws -> [Float] {
                if first == nil { first = features }
                return [Float](repeating: 1, count: frames * FeatureConfig.bins)
            }
        }
        let x = CleanFixture.noiseAndTone(frames: Chunker.window)
        let spy = Spy()
        _ = try CleanFixture.clean(x, model: spy)
        let want = Fbank(dither: .seeded(Cleaner.ditherSeed)).features(scaled: x.map { $0 * FeatureConfig.scale })
        let got = try XCTUnwrap(spy.first)
        XCTAssertEqual(got.count, want.count)
        guard got.count == want.count else { return }
        XCTAssertEqual(Fixture.maxAbsDiff(got, want), 0, "the model must see the features of the x32768 waveform, dithered with the documented seed")
        XCTAssertGreaterThan(got.map(abs).max() ?? 0, 5)
    }

    // MARK: refusals (typed, never a trap)

    func testAnEmptyClipIsRefused() throws {
        let empty = MappedFloatWav(info: WavInfo(sampleRate: 48000, channels: 1, frames: 0, dataOffset: 0), data: Data())
        let out = CleanFixture.tmpWav()
        let w = try WavIO.StreamWriter(url: out, sampleRate: 48000, channels: 1)
        defer { w.abandon() }
        XCTAssertThrowsError(try Cleaner(model: Constant(v: 1)).run(input: empty, output: w, progress: nil)) {
            XCTAssertEqual(($0 as? Failure)?.reason, "empty")
            XCTAssertEqual(($0 as? Failure)?.exitCode, .input)
        }
    }

    func testANonFiniteSampleIsRefusedBeforeAnyWork() throws {
        for bad in [Float.nan, .infinity, -.infinity, 1e36] {  // 1e36 x 32768 overflows float32
            var x = CleanFixture.noiseAndTone(frames: 1_000_000)
            x[990_000] = bad
            var windowsSeen = 0
            struct Counting: MaskPredicting {
                let bump: () -> Void
                func mask(features: [Float], frames: Int) throws -> [Float] { bump(); return [] }
            }
            XCTAssertThrowsError(try CleanFixture.clean(x, model: Counting(bump: { windowsSeen += 1 })), "\(bad)") {
                XCTAssertEqual(($0 as? Failure)?.reason, "non_finite")
                XCTAssertEqual(($0 as? Failure)?.exitCode, .input)
            }
            XCTAssertEqual(windowsSeen, 0, "a refused file must cost no model time")
        }
    }

    func testAWrongLengthMaskThrowsAndDoesNotTrap() throws {
        struct Short: MaskPredicting {
            let drop: Int
            func mask(features: [Float], frames: Int) throws -> [Float] {
                [Float](repeating: 1, count: max(0, frames * FeatureConfig.bins - drop))
            }
        }
        for drop in [1, 961, 2496 * 961] {
            XCTAssertThrowsError(try CleanFixture.clean(CleanFixture.noiseAndTone(frames: 48_000), model: Short(drop: drop)), "drop \(drop)") {
                XCTAssertEqual(($0 as? Failure)?.reason, "mask_length")
            }
        }
    }

    func testAModelErrorIsPassedOnAsAFailure() throws {
        struct Boom: MaskPredicting {
            struct Odd: Error {}
            func mask(features: [Float], frames: Int) throws -> [Float] { throw Odd() }
        }
        XCTAssertThrowsError(try CleanFixture.clean(CleanFixture.noiseAndTone(frames: 48_000), model: Boom())) {
            XCTAssertEqual(($0 as? Failure)?.reason, "predict")
        }
    }

    func testANonFiniteMaskIsRefusedNotWritten() throws {
        XCTAssertThrowsError(try CleanFixture.clean(CleanFixture.noiseAndTone(frames: 48_000), model: Constant(v: .nan))) {
            XCTAssertEqual(($0 as? Failure)?.reason, "non_finite_output")
        }
    }

    func testAShortReadIsRefused() {
        var out: [Float] = []
        XCTAssertThrowsError(try Cleaner(model: Constant(v: 1)).run(
            sampleCount: 1_000_000, read: { r in [Float](repeating: 0.1, count: r.count - 1) },
            emit: { out += $0 }, progress: nil)) {
            XCTAssertEqual(($0 as? Failure)?.reason, "short_read")
        }
        XCTAssertTrue(out.isEmpty)
        // The tiled path of a short clip reads the whole clip once; a short read there must not reach the Chunker's precondition.
        XCTAssertThrowsError(try Cleaner(model: Constant(v: 1)).run(
            sampleCount: 48_000, read: { _ in [Float](repeating: 0.1, count: 10) }, emit: { out += $0 }, progress: nil)) {
            XCTAssertEqual(($0 as? Failure)?.reason, "short_read")
        }
    }

    // MARK: progress

    func testProgressIsMonotonicAndEndsAtOne() throws {
        var seen: [Double] = []
        _ = try CleanFixture.clean(CleanFixture.noiseAndTone(frames: 1_700_001), model: Constant(v: 1), progress: { seen.append($0) })
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(seen.last, 1.0)
        XCTAssertEqual(seen.first ?? 0, 1.0 / 3.0, accuracy: 1e-12)
    }

    // MARK: Spectrum construction (#466)

    func testSpectrumConstructionThrowsWhenTheOSHasNoDFTKernel() {
        XCTAssertThrowsError(try Spectrum(makeSetup: { _ in nil })) {
            XCTAssertEqual(($0 as? Failure)?.reason, "dft_setup")
        }
        XCTAssertNoThrow(try Spectrum())
    }
}
