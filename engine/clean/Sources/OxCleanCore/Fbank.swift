import Accelerate
import Foundation

/// Feature extraction constants for MossFormer2_SE_48K (Kaldi fbank, 40 ms / 8 ms at 48 kHz).
public enum FeatureConfig {
    public static let sampleRate = 48000
    public static let frameLength = 1920
    public static let frameShift = 384
    public static let mels = 60
    public static let bins = 961
    public static let scale: Float = 32768
}

/// Dither added to every Kaldi frame before DC removal (torchaudio order). `.none` is the production-neutral path and
/// the oracle path; `.seeded` draws sigma-1.0 Gaussian noise (in the x32768 domain) from a fixed-seed generator.
public enum Dither: Equatable, Sendable {
    case none
    case seeded(UInt64)
}

/// Platform-independent Gaussian source: SplitMix64 integer stream (exact on every platform), turned into N(0,1) with
/// Box-Muller in Double and rounded to Float. Only the transcendental step touches libm; a 1-ulp libm difference in
/// Double can flip a Float rounding in the last bit at most, far below anything a feature can see.
/// Draw order: per pair, u1 from the first word, u2 from the second, `r cos` first, then `r sin`.
struct GaussianNoise {
    private var state: UInt64
    private var spare: Float?

    init(seed: UInt64) { state = seed }

    private mutating func word() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static let unit = 1.0 / 9_007_199_254_740_992.0  // 2^-53

    mutating func next() -> Float {
        if let s = spare { spare = nil; return s }
        let u1 = (Double(word() >> 11) + 0.5) * Self.unit  // (0, 1): never 0, so log is finite
        let u2 = (Double(word() >> 11) + 0.5) * Self.unit
        let r = (-2.0 * log(u1)).squareRoot()
        let theta = 2.0 * Double.pi * u2
        spare = Float(r * sin(theta))
        return Float(r * cos(theta))
    }

    /// `x[i] += next()` for `count` values, same sequence as repeated `next()`, with the log/sin/cos done in batches
    /// by vForce (the per-call libm cost dominated the whole feature pass). `scratch` is caller-owned so the hot loop
    /// never allocates; it must hold at least `2 * count` doubles.
    mutating func add(to x: UnsafeMutablePointer<Float>, count: Int, scratch: UnsafeMutablePointer<Double>) {
        var i = 0
        if i < count, let s = spare { x[i] += s; spare = nil; i += 1 }
        let pairs = (count - i) / 2
        if pairs > 0 {
            let r = scratch, theta = scratch + pairs, sn = scratch + 2 * pairs, cs = scratch + 3 * pairs
            for j in 0..<pairs {
                r[j] = (Double(word() >> 11) + 0.5) * Self.unit
                theta[j] = 2.0 * Double.pi * ((Double(word() >> 11) + 0.5) * Self.unit)
            }
            var n = Int32(pairs)
            vvlog(r, r, &n)
            for j in 0..<pairs { r[j] *= -2.0 }
            vvsqrt(r, r, &n)
            vvsincos(sn, cs, theta, &n)
            for j in 0..<pairs {
                x[i + 2 * j] += Float(r[j] * cs[j])
                x[i + 2 * j + 1] += Float(r[j] * sn[j])
            }
            i += 2 * pairs
        }
        while i < count { x[i] += next(); i += 1 }
    }
}

/// Kaldi `compute-fbank-feats` as torchaudio implements it, plus two `compute_deltas` passes:
/// 40 ms Hamming frames every 8 ms (snip_edges), DC removal, 0.97 pre-emphasis, FFT 2048, power spectrum,
/// 60 Kaldi-mel (1127 ln) filters 20 Hz..Nyquist, natural log floored at float eps.
public struct Fbank {
    static let fftSize = 2048
    static let log2n: vDSP_Length = 11
    static let preemphasis: Float = 0.97
    static let epsilon = Float.ulpOfOne

    let dither: Dither

    public init(dither: Dither = .none) { self.dither = dither }

    /// One triangular filter: weights for FFT bins `start ..< start + weights.count`.
    private struct Filter { var start: Int; var weights: [Float] }

    private static func kaldiMel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }

    /// 60 filters over bins 0..<1024 (torchaudio pads a zero column for bin 1024).
    private static let filters: [Filter] = {
        let binWidth = Double(FeatureConfig.sampleRate) / Double(fftSize)
        let melLow = kaldiMel(20.0), melHigh = kaldiMel(Double(FeatureConfig.sampleRate) / 2)
        let delta = (melHigh - melLow) / Double(FeatureConfig.mels + 1)
        return (0..<FeatureConfig.mels).map { b in
            let left = melLow + Double(b) * delta, center = melLow + Double(b + 1) * delta
            let right = melLow + Double(b + 2) * delta
            var w = [Float](repeating: 0, count: fftSize / 2)
            for k in 0..<(fftSize / 2) {
                let mel = kaldiMel(binWidth * Double(k))
                w[k] = Float(max(0, min((mel - left) / (center - left), (right - mel) / (right - center))))
            }
            let first = w.firstIndex { $0 > 0 } ?? 0, last = w.lastIndex { $0 > 0 } ?? 0
            return Filter(start: first, weights: Array(w[first...max(first, last)]))
        }
    }()

    /// Non-periodic Hamming, as torchaudio's `hamming_window(periodic=False)`.
    private static let window: [Float] = (0..<FeatureConfig.frameLength).map {
        Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double($0) / Double(FeatureConfig.frameLength - 1)))
    }

    private func frameCount(_ n: Int) -> Int {
        n < FeatureConfig.frameLength ? 0 : 1 + (n - FeatureConfig.frameLength) / FeatureConfig.frameShift
    }

    /// Copy frame `f`, add dither, remove the DC offset. `frame` is `frameLength` long.
    private func condition(_ samples: UnsafeBufferPointer<Float>, frame f: Int, noise: inout GaussianNoise?, scratch: UnsafeMutablePointer<Double>,
                           into frame: UnsafeMutablePointer<Float>) {
        let L = FeatureConfig.frameLength
        frame.update(from: samples.baseAddress! + f * FeatureConfig.frameShift, count: L)
        if noise != nil { noise!.add(to: frame, count: L, scratch: scratch) }  // sigma 1.0
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(L))
        var neg = -mean
        vDSP_vsadd(frame, 1, &neg, frame, 1, vDSP_Length(L))
    }

    private func makeNoise() -> GaussianNoise? {
        if case .seeded(let s) = dither { return GaussianNoise(seed: s) }
        return nil
    }

    /// Frames after dither and DC removal, `[frames, 1920]` row-major (test hook for the dither order).
    func conditionedFrames(scaled samples: [Float]) -> [Float] {
        let frames = frameCount(samples.count), L = FeatureConfig.frameLength
        var out = [Float](repeating: 0, count: frames * L)
        var noise = makeNoise()
        var scratch = [Double](repeating: 0, count: 2 * L)
        samples.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                scratch.withUnsafeMutableBufferPointer { sc in
                    for f in 0..<frames {
                        condition(s, frame: f, noise: &noise, scratch: sc.baseAddress!, into: o.baseAddress! + f * L)
                    }
                }
            }
        }
        return out
    }

    /// `samples` are the waveform already multiplied by 32768. Returns `[frames, 180]` row-major:
    /// 60 log-mel, 60 delta, 60 delta-delta.
    public func features(scaled samples: [Float]) -> [Float] {
        let frames = frameCount(samples.count)
        guard frames > 0 else { return [] }
        let L = FeatureConfig.frameLength, N = Self.fftSize, M = FeatureConfig.mels
        var mel = [Float](repeating: 0, count: frames * M)
        let filters = Self.filters, window = Self.window
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        // All scratch is allocated once, outside the frame loop.
        var frame = [Float](repeating: 0, count: N)  // [L..<N] stays zero: the FFT zero padding
        var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
        var power = [Float](repeating: 0, count: N / 2)
        var noise = makeNoise()
        var scratch = [Double](repeating: 0, count: 2 * L)
        samples.withUnsafeBufferPointer { s in
          scratch.withUnsafeMutableBufferPointer { sc in
            frame.withUnsafeMutableBufferPointer { fr in
                re.withUnsafeMutableBufferPointer { r in
                    im.withUnsafeMutableBufferPointer { i in
                        power.withUnsafeMutableBufferPointer { p in
                            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                            let x = fr.baseAddress!
                            for f in 0..<frames {
                                condition(s, frame: f, noise: &noise, scratch: sc.baseAddress!, into: x)
                                // pre-emphasis, replicate-padded: x[0] -= 0.97 x[0]
                                var k = L - 1
                                while k > 0 { x[k] -= Self.preemphasis * x[k - 1]; k -= 1 }
                                x[0] -= Self.preemphasis * x[0]
                                vDSP_vmul(x, 1, window, 1, x, 1, vDSP_Length(L))
                                x.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) {
                                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(N / 2))
                                }
                                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                                // zrip output is 2x the DFT; bin 0 and Nyquist are packed in realp[0], imagp[0].
                                let dc = r[0] * 0.5
                                vDSP_zvmags(&split, 1, p.baseAddress!, 1, vDSP_Length(N / 2))
                                var quarter: Float = 0.25
                                vDSP_vsmul(p.baseAddress!, 1, &quarter, p.baseAddress!, 1, vDSP_Length(N / 2))
                                p[0] = dc * dc  // bin 1024 (Nyquist) has zero mel weight and is not used
                                for b in 0..<M {
                                    let flt = filters[b]
                                    var acc: Float = 0
                                    flt.weights.withUnsafeBufferPointer {
                                        vDSP_dotpr(p.baseAddress! + flt.start, 1, $0.baseAddress!, 1, &acc, vDSP_Length($0.count))
                                    }
                                    mel[f * M + b] = logf(max(acc, Self.epsilon))
                                }
                            }
                        }
                    }
                }
            }
          }
        }
        let d1 = Self.deltas(mel, frames: frames)
        let d2 = Self.deltas(d1, frames: frames)
        var out = [Float](repeating: 0, count: frames * 3 * M)
        for f in 0..<frames {
            for b in 0..<M {
                out[f * 3 * M + b] = mel[f * M + b]
                out[f * 3 * M + M + b] = d1[f * M + b]
                out[f * 3 * M + 2 * M + b] = d2[f * M + b]
            }
        }
        return out
    }

    /// torchaudio `compute_deltas(win_length=5, mode="replicate")` along time of a `[frames, 60]` matrix:
    /// `sum_{n=1,2} n (c[t+n] - c[t-n]) / 10`, indices clamped to the edges.
    private static func deltas(_ c: [Float], frames: Int) -> [Float] {
        let M = FeatureConfig.mels
        var out = [Float](repeating: 0, count: c.count)
        for t in 0..<frames {
            let p1 = min(t + 1, frames - 1), m1 = max(t - 1, 0), p2 = min(t + 2, frames - 1), m2 = max(t - 2, 0)
            for b in 0..<M {
                out[t * M + b] = ((c[p1 * M + b] - c[m1 * M + b]) + 2 * (c[p2 * M + b] - c[m2 * M + b])) / 10
            }
        }
        return out
    }
}
