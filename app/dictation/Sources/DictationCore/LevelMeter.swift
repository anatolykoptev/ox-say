import Accelerate
import Foundation

/// Turns the latest microphone samples into a few loudness levels, one per
/// frequency band across the speech range, for the "it hears you" animation.
/// Levels are 0 (silence, or quieter than `floorDB`) to 1 (`ceilingDB` or louder).
/// Not thread-safe: use one meter from one thread (the audio tap).
public final class LevelMeter {
    public let bands: Int
    public var floorDB: Float = -75
    public var ceilingDB: Float = -25

    private let size: Int
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private let window: [Float]
    /// Bin index where each band starts; the last entry is where the last band ends.
    private let edges: [Int]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    /// - Parameters:
    ///   - size: FFT length, a power of two. 512 at 16 kHz is a 32 ms window.
    ///   - low, high: the frequency range the bands cover, spaced logarithmically.
    public init(bands: Int = 9, sampleRate: Double = 16000, size: Int = 512, low: Double = 100, high: Double = 5000) {
        precondition(bands > 0 && size >= 64 && size & (size - 1) == 0)
        self.bands = bands
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let binHz = sampleRate / Double(size)
        let nyquistBin = size / 2
        var edges: [Int] = []
        for i in 0...bands {
            let hz = low * pow(high / low, Double(i) / Double(bands))
            edges.append(min(nyquistBin, max(1, Int((hz / binHz).rounded()))))
        }
        // Every band gets at least one bin of its own.
        for i in 1..<edges.count where edges[i] <= edges[i - 1] {
            edges[i] = min(nyquistBin, edges[i - 1] + 1)
        }
        self.edges = edges
        frame = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Levels for the newest `size` samples (zero-padded in front when fewer).
    public func levels(_ samples: [Float]) -> [Float] {
        let n = min(samples.count, size)
        for i in 0..<(size - n) { frame[i] = 0 }
        for i in 0..<n { frame[size - n + i] = samples[samples.count - n + i] }
        vDSP.multiply(frame, window, result: &frame)

        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }
        // zrip scales by 2; with the Hann window's 0.5 gain a full-scale sine
        // lands near 0 dB after dividing its magnitude by size / 2.
        let scale = Float(size * size) / 4
        let span = ceilingDB - floorDB
        return (0..<bands).map { b in
            let lo = edges[b], hi = max(edges[b + 1], lo + 1)
            var peak: Float = 0
            for k in lo..<min(hi, power.count) { peak = max(peak, power[k]) }
            let db = 10 * log10(peak / scale + 1e-12)
            return min(1, max(0, (db - floorDB) / span))
        }
    }
}
