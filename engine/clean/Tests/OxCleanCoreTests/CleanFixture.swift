import Foundation
@testable import OxCleanCore

/// Deterministic clips and temp files for the pipeline tests.
enum CleanFixture {
    /// A 440 Hz tone with a little noise, peak about 0.3: stands in for audio the stub models pass through.
    static func noiseAndTone(frames n: Int) -> [Float] {
        var noise = GaussianNoise(seed: 7)
        return (0..<n).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / 48000)) + 0.02 * noise.next() }
    }

    static func tmpWav() -> URL { WavFixture.tmp("clean-out") }

    /// Runs `Cleaner` over `x` through real files and reads the result back.
    static func clean(_ x: [Float], model: MaskPredicting, dither: Dither = .seeded(Cleaner.ditherSeed),
                      progress: ((Double) -> Void)? = nil) throws -> [Float] {
        let inURL = try WavFixture.write(rate: 48000, channels: 1, samples: x)
        let outURL = tmpWav()
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }
        let w = try WavIO.StreamWriter(url: outURL, sampleRate: 48000, channels: 1)
        try Cleaner(model: model, dither: dither).run(input: WavIO.readMono48k(inURL), output: w, progress: progress)
        try w.finish()
        let y = try WavIO.readMono48k(outURL)
        return y.window(start: 0, count: y.info.frames)
    }
}

/// A mask of one constant value, whatever the features.
struct Constant: MaskPredicting {
    let v: Float
    func mask(features: [Float], frames: Int) throws -> [Float] { [Float](repeating: v, count: frames * FeatureConfig.bins) }
}
