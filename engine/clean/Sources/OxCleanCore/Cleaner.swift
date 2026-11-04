import Accelerate
import Foundation

/// What a run cost, split by stage, for the CLI's stats line and the speed acceptance.
public struct CleanStats: Equatable {
    public var windows = 0
    public var totalSeconds: Double = 0
    public var featureSeconds: Double = 0
    public var modelSeconds: Double = 0
    public var spectralSeconds: Double = 0
}

/// The windowed cleaning pipeline: read a window, scale by 32768, features, mask, STFT, apply, iSTFT, divide by 32768,
/// splice, write. One window at a time, so memory is a few windows plus the model however long the file is.
///
/// NaN and Inf: the file is REFUSED (`Failure.input("non_finite")`), before any model time is spent. A float WAV with a
/// non-finite sample is a broken upstream file, and a single such sample would poison about ten feature frames, so
/// replacing it with 0 would hide a corrupt input behind a plausible-looking result.
public struct Cleaner {
    /// Seed of the dither (decision 4: sigma 1.0 in the x32768 domain). Every window draws from a generator seeded with
    /// this value, so a given window alignment always gives the same output. The ASCII bytes "OXCLEAN1".
    public static let ditherSeed: UInt64 = 0x4F58_434C_4541_4E31

    static let frames = ModelContract.frames

    private let model: MaskPredicting
    private let dither: Dither

    /// `dither` is `.seeded(ditherSeed)` in production. `.none` exists for the golden test, which compares against a
    /// PyTorch reference at dither 0.
    public init(model: MaskPredicting, dither: Dither = .seeded(Cleaner.ditherSeed)) {
        self.model = model
        self.dither = dither
    }

    /// Cleans `input` into `output` and returns the cost. Does not finish or abandon `output`: the caller does.
    @discardableResult
    public func run(input: MappedFloatWav, output: WavIO.StreamWriter, progress: ((Double) -> Void)? = nil) throws -> CleanStats {
        try run(sampleCount: input.info.frames,
                read: { input.window(start: $0.lowerBound, count: $0.count) },
                emit: { samples in try samples.withUnsafeBufferPointer { try output.append($0) } },
                progress: progress)
    }

    /// The pipeline over any source of samples and any sink, which is what lets a test make a read come back short.
    func run(sampleCount n: Int, read: (Range<Int>) throws -> [Float], emit: ([Float]) throws -> Void,
             progress: ((Double) -> Void)?) throws -> CleanStats {
        guard n > 0 else { throw Failure.input("empty", detail: "The audio file has no samples.") }
        let clock = ContinuousClock()
        let started = clock.now
        var stats = CleanStats()
        try Self.requireFinite(sampleCount: n, read: read)
        let chunker = Chunker(sampleCount: n)
        var splicer = WindowSplicer(chunker: chunker)
        let spectrum = try Spectrum()
        let fbank = Fbank(dither: dither)
        let bins = FeatureConfig.bins

        for k in 0..<chunker.windowCount {
            let raw = try chunker.inputWindow(k) { range in
                let samples = try read(range)
                guard samples.count == range.count else {
                    throw Failure.input("short_read", detail: "The audio file ended early: read \(samples.count) of \(range.count) samples.")
                }
                return samples
            }
            guard raw.count == Chunker.window else {
                throw Failure.processing("window_length", detail: "A window came out \(raw.count) samples long, not \(Chunker.window).")
            }
            let scaled = raw.map { $0 * FeatureConfig.scale }

            var t = clock.now
            let features = fbank.features(scaled: scaled)
            guard features.count == Self.frames * ModelContract.features else {
                throw Failure.processing("features_length", detail: "The feature pass returned \(features.count) values, not \(Self.frames * ModelContract.features).")
            }
            stats.featureSeconds += (clock.now - t).seconds

            t = clock.now
            let mask: [Float]
            do { mask = try model.mask(features: features, frames: Self.frames) } catch let f as Failure { throw f } catch {
                throw Failure.processing("predict", detail: "The voice-cleanup model failed: \(error.localizedDescription)")
            }
            guard mask.count == Self.frames * bins else {
                throw Failure.processing("mask_length", detail: "The model returned \(mask.count) mask values, not \(Self.frames * bins).")
            }
            stats.modelSeconds += (clock.now - t).seconds

            t = clock.now
            var (re, im, frameCount) = spectrum.stft(scaled: scaled)
            guard frameCount == Self.frames else {
                throw Failure.processing("stft_frames", detail: "The spectrum has \(frameCount) frames, not \(Self.frames).")
            }
            spectrum.apply(mask: mask, re: &re, im: &im)
            let cleaned = spectrum.istft(re: re, im: im, frames: frameCount, length: Chunker.window).map { $0 / FeatureConfig.scale }
            guard cleaned.allSatisfy(\.isFinite) else {
                throw Failure.processing("non_finite_output", detail: "The model produced a non-finite result for window \(k + 1); nothing was written for it.")
            }
            stats.spectralSeconds += (clock.now - t).seconds

            try emit(splicer.push(cleaned))
            stats.windows += 1
            progress?(Double(k + 1) / Double(chunker.windowCount))
        }
        guard splicer.isComplete, splicer.emittedCount == n else {
            throw Failure.processing("incomplete", detail: "The output has \(splicer.emittedCount) of \(n) samples.")
        }
        stats.totalSeconds = (clock.now - started).seconds
        return stats
    }

    /// Reads the clip once in large blocks and refuses the first sample whose x32768 value is not finite.
    static func requireFinite(sampleCount n: Int, read: (Range<Int>) throws -> [Float]) throws {
        let block = 1 << 20
        var start = 0
        while start < n {
            let range = start..<min(n, start + block)
            let samples = try read(range)
            guard samples.count == range.count else {
                throw Failure.input("short_read", detail: "The audio file ended early: read \(samples.count) of \(range.count) samples.")
            }
            if let bad = samples.firstIndex(where: { !($0 * FeatureConfig.scale).isFinite }) {
                throw Failure.input("non_finite", detail: "The audio file has a sample that is not a finite number (at \(start + bad)); it cannot be cleaned.")
            }
            start = range.upperBound
        }
    }
}
