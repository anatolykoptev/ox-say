import Darwin
import XCTest
@testable import OxCleanCore

/// Tests that need the real weights. Skipped unless OX_CLEAN_MODELS names the models dir (the parent of
/// `mossformer2-se-48k`); OX_CLEAN_REQUIRE_MODELS=1 turns the skip into a failure (Task 9's CI).
final class ModelGoldenTests: XCTestCase {
    static let env = ProcessInfo.processInfo.environment

    /// Loaded once for the class: a load costs about 7 s of GPU kernel compile and 0.4 GiB.
    nonisolated(unsafe) static let loaded: Result<(model: MaskModel, wallSeconds: Double), Error> = Result {
        let dir = URL(fileURLWithPath: (env["OX_CLEAN_MODELS"] ?? "") as String)
        let t0 = ContinuousClock.now
        let m = try MaskModel(modelsDir: dir)
        return (m, (ContinuousClock.now - t0).seconds)
    }

    func model() throws -> MaskModel {
        guard let dir = Self.env["OX_CLEAN_MODELS"], !dir.isEmpty else {
            if Self.env["OX_CLEAN_REQUIRE_MODELS"] == "1" { XCTFail("OX_CLEAN_REQUIRE_MODELS=1 but OX_CLEAN_MODELS is not set") }
            throw XCTSkip("set OX_CLEAN_MODELS to run the real-model tests")
        }
        return try Self.loaded.get().model
    }

    func testTheModelLoadsAndPassesItsKnownAnswer() throws {
        let m = try model()
        let s = m.stats
        print("MODEL load \(s.loadSeconds) s, first prediction (known answer) \(s.firstPredictionSeconds) s, "
              + "known answer mse \(s.knownAnswerMSE) p99.9 \(s.knownAnswerP999) max \(s.knownAnswerMaxAbs), units \(ComputeChoice.current().units.rawValue)")
        XCTAssertLessThanOrEqual(s.knownAnswerMSE, KnownAnswer.mseLimit)
        XCTAssertLessThanOrEqual(s.knownAnswerP999, KnownAnswer.p999Limit)
    }

    func testCoreMLMaskMatchesTheTorchGolden() throws {
        let m = try model()
        let dir = URL(fileURLWithPath: Self.env["OX_CLEAN_MODELS"]!).appendingPathComponent(MaskModel.directoryName)
        let ref = try ReferenceWindow.read(dir.appendingPathComponent("reference_window.bin"))
        let got = try m.mask(features: ref.features, frames: 2496)
        let stats = KnownAnswer.measure(got: got, want: ref.mask)
        print("GOLDEN mask mse \(stats.mse) p99.9 \(stats.p999) max \(stats.maxAbs)")
        XCTAssertTrue(KnownAnswer.passes(stats), "\(stats)")
        XCTAssertLessThan(stats.mse, 1e-4)
    }

    func testASecondLoadInTheSameProcess() throws {
        let first = try model().stats
        let dir = URL(fileURLWithPath: Self.env["OX_CLEAN_MODELS"]!)
        let t0 = ContinuousClock.now
        let second = try MaskModel(modelsDir: dir)
        let wall = (ContinuousClock.now - t0).seconds
        print("SECOND LOAD same process: wall \(wall) s, load \(second.stats.loadSeconds) s, first prediction \(second.stats.firstPredictionSeconds) s "
              + "(first load: \(first.loadSeconds) s / \(first.firstPredictionSeconds) s)")
        XCTAssertLessThanOrEqual(second.stats.knownAnswerMSE, KnownAnswer.mseLimit)
    }

    // MARK: end to end

    func testTwentyOneSecondGoldenEndToEnd() throws {
        let m = try model()
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Fixture.dir.appendingPathComponent("golden21_meta.json"))) as? [String: Any])
        let n = try XCTUnwrap(meta["samples"] as? Int)
        let scale = try XCTUnwrap(meta["ref_scale"] as? Double)
        let x = GoldenClip.samples(n)
        // The generator is mirrored in gen_golden_e2e.py; spot-check it against values Python wrote.
        let probes = try XCTUnwrap(meta["input_probes"] as? [[String: Any]])
        for p in probes {
            let at = try XCTUnwrap(p["at"] as? Int), want = try XCTUnwrap(p["values"] as? [Double])
            for (i, w) in want.enumerated() { XCTAssertEqual(Double(x[at + i]), w, accuracy: 2e-6, "input sample \(at + i)") }
        }
        let refData = try Data(contentsOf: Fixture.dir.appendingPathComponent("golden21_ref.i16"))
        XCTAssertEqual(refData.count, n * 2)
        let ref: [Float] = refData.withUnsafeBytes { raw in
            (0..<n).map { Float(Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / scale) }
        }
        XCTAssertGreaterThan(Chunker(sampleCount: n).windowCount, 1, "the golden must cross a seam")
        let t0 = ContinuousClock.now
        let y = try CleanFixture.clean(x, model: m, dither: .none)
        let secs = (ContinuousClock.now - t0).seconds
        let sdr = Fixture.siSdr(y, ref)
        print("E2E golden: \(n) samples, \(Chunker(sampleCount: n).windowCount) windows, SI-SDR vs PyTorch reference \(sdr) dB, \(secs) s")
        XCTAssertGreaterThanOrEqual(sdr, 30)
        // The reference is not silence: a vacuous match against zeros would pass SI-SDR.
        XCTAssertGreaterThan(Fixture.rms(ref), 1e-3)
    }

    // MARK: speed and memory (live acceptance; OX_CLEAN_BENCH=1, best under `swift test -c release -Xswiftc -enable-testing`)

    func testEndToEndSpeedAndMemory() throws {
        guard Self.env["OX_CLEAN_BENCH"] == "1" else { throw XCTSkip("set OX_CLEAN_BENCH=1 to measure speed") }
        let m = try model()
        let minutes = Double(Self.env["OX_CLEAN_BENCH_SECONDS"] ?? "150") ?? 150
        let n = Int(minutes * 48000)
        let x = GoldenClip.samples(n)
        let inURL = try WavFixture.write(rate: 48000, channels: 1, samples: x)
        let outURL = CleanFixture.tmpWav()
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }
        // Warm: one window through the loaded model has already run (known answer); run one full pass untimed for the front end.
        let w = try WavIO.StreamWriter(url: outURL, sampleRate: 48000, channels: 1)
        let t0 = ContinuousClock.now
        let stats = try Cleaner(model: m).run(input: WavIO.readMono48k(inURL), output: w, progress: nil)
        try w.finish()
        let secs = (ContinuousClock.now - t0).seconds
        let peak = Self.peakFootprintGiB()
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        print("SPEED \(config): \(minutes) s of audio in \(secs) s = \(minutes / secs)x real time; peak footprint \(peak) GiB; stats \(stats)")
        XCTAssertGreaterThanOrEqual(minutes / secs, 8, "end-to-end speed gate (\(config) build)")
    }

    static func peakFootprintGiB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_073_741_824 : -1
    }
}

extension Fixture {
    static func rms(_ x: [Float]) -> Double { (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot() }
}

/// The synthetic voiced clip of the end-to-end golden. `gen_golden_e2e.py` implements the same formulas in numpy; no
/// recording is involved. Voiced harmonics (pitch glide 110 to 170 Hz, formant-weighted) under a syllable envelope with
/// pauses, plus SplitMix64 Gaussian noise.
enum GoldenClip {
    static func samples(_ n: Int) -> [Float] {
        var noise = GaussianNoise(seed: 20261104)
        var out = [Float](repeating: 0, count: n)
        let twoPi = 2 * Double.pi
        for i in 0..<n {
            let t = Double(i) / 48000
            let f0 = 110 + 60 * (0.5 - 0.5 * cos(twoPi * t / 3.7))
            let phase = twoPi * (140 * t - (30 * 3.7 / twoPi) * sin(twoPi * t / 3.7))
            var v = 0.0
            for h in 1...24 {
                let f = Double(h) * f0
                if f >= 8000 { break }
                let a = 0.6 * exp(-pow((f - 700) / 250, 2)) + 0.4 * exp(-pow((f - 1500) / 400, 2)) + 0.2 * exp(-pow((f - 2600) / 500, 2)) + 0.05
                v += a / Double(h) * sin(Double(h) * phase)
            }
            let syll = pow(0.5 + 0.5 * sin(twoPi * 3.1 * t - Double.pi / 2), 1.5)
            let gate = (t / 6.1).truncatingRemainder(dividingBy: 1) < 0.85 ? 1.0 : 0.0
            out[i] = Float(0.12 * v * syll * gate) + 0.003 * noise.next()
        }
        return out
    }
}
