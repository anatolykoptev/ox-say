import Accelerate
import Foundation

/// STFT, iSTFT and mask application for MossFormer2_SE_48K, matching
/// `torch.stft(x, 1920, hop_length=384, win_length=1920, window=hamming_window(1920, periodic=False), center=False,
/// onesided=True, return_complex=False)` and `torch.istft(..., center=False, length=n)`.
///
/// Spectra are `[frames, 961]` row-major, real and imaginary parts in separate arrays.
///
/// Concurrency: `Spectrum` has no stored state. The window is an immutable `static let`, and every call creates its own
/// vDSP DFT setups and scratch buffers (once per call, never per frame) and frees them before returning, so one value
/// may be used from any number of threads at once.
public struct Spectrum: Sendable {
    static let fftSize = FeatureConfig.frameLength  // 1920 = 15 x 2^7, in vDSP's supported set f x 2^n, f in {1,3,5,15}
    static let hop = FeatureConfig.frameShift  // 384
    static let bins = FeatureConfig.bins  // 961
    static let half = fftSize / 2  // 960 complex pairs in vDSP's packed real-DFT layout

    /// Non-periodic Hamming (`N - 1` in the denominator), as `torch.hamming_window(1920, periodic=False)`.
    static let window: [Float] = (0..<fftSize).map {
        Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double($0) / Double(fftSize - 1)))
    }
    /// `window / 2`: vDSP's forward real DFT returns twice the DFT, and halving is exact in floating point.
    private static let analysisWindow: [Float] = window.map { $0 * 0.5 }
    private static let windowSquared: [Float] = window.map { $0 * $0 }

    /// Checks that this OS has the 1920-point real DFT in both directions, so `stft` and `istft` cannot meet a missing
    /// kernel later. Throws (instead of trapping, #466) where it is missing.
    public init() throws { try self.init(makeSetup: Self.makeSetup) }

    /// `makeSetup` is the vDSP call, replaceable so a test can make it return nil.
    init(makeSetup: (vDSP_DFT_Direction) -> vDSP_DFT_Setup?) throws {
        for direction in [vDSP_DFT_Direction.FORWARD, .INVERSE] {
            guard let setup = makeSetup(direction) else {
                throw Failure.processing("dft_setup", detail: "This macOS has no 1920-point real FFT, which voice cleanup needs.")
            }
            vDSP_DFT_DestroySetup(setup)
        }
    }

    /// A real-DFT setup for 1920 points. `nil` would mean this OS lacks the radix-15 kernel; the tests probe it.
    static func makeSetup(_ direction: vDSP_DFT_Direction) -> vDSP_DFT_Setup? {
        vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), direction)
    }

    /// Only reached after `init` has proved the kernel exists, so a nil here would be an allocation failure.
    private static func requireSetup(_ direction: vDSP_DFT_Direction) -> vDSP_DFT_Setup {
        guard let setup = makeSetup(direction) else {
            preconditionFailure("vDSP has no 1920-point real DFT on this OS")
        }
        return setup
    }

    static func frameCount(samples n: Int) -> Int {
        n < fftSize ? 0 : 1 + (n - fftSize) / hop
    }

    /// Samples covered by `frames` overlapping frames: `torch.istft`'s `expected_output_signal_len` with center=False.
    static func coveredLength(frames: Int) -> Int {
        frames == 0 ? 0 : fftSize + hop * (frames - 1)
    }

    /// `sum w^2` over the overlapping frames, length `coveredLength(frames:)`. The smallest value is `w[0]^2 = 0.0064`
    /// (the first and last 384 samples, covered by a single frame), so `torch.istft`'s "window overlap add min < 1e-11"
    /// error cannot happen with these parameters and `istft` needs no failing path.
    static func envelope(frames: Int) -> [Float] {
        var env = [Float](repeating: 0, count: coveredLength(frames: frames))
        env.withUnsafeMutableBufferPointer { e in
            windowSquared.withUnsafeBufferPointer { w in
                for f in 0..<frames {
                    let p = e.baseAddress! + f * hop
                    vDSP_vadd(p, 1, w.baseAddress!, 1, p, 1, vDSP_Length(fftSize))
                }
            }
        }
        return env
    }

    /// `scaled` is the waveform already multiplied by 32768. A signal shorter than one frame has no frames (torch raises
    /// there); samples after the last whole hop are not analysed (torch drops them too).
    public func stft(scaled samples: [Float]) -> (re: [Float], im: [Float], frames: Int) {
        let frames = Self.frameCount(samples: samples.count)
        guard frames > 0 else { return ([], [], 0) }
        let N = Self.fftSize, H = Self.half, B = Self.bins
        var re = [Float](repeating: 0, count: frames * B)
        var im = [Float](repeating: 0, count: frames * B)  // bins 0 and 960 keep imaginary part 0

        let setup = Self.requireSetup(.FORWARD)
        defer { vDSP_DFT_DestroySetup(setup) }
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: N)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4 * H)
        defer { frame.deallocate(); scratch.deallocate() }
        let inRe = scratch, inIm = scratch + H, outRe = scratch + 2 * H, outIm = scratch + 3 * H

        samples.withUnsafeBufferPointer { s in
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    Self.analysisWindow.withUnsafeBufferPointer { w in
                        var split = DSPSplitComplex(realp: inRe, imagp: inIm)
                        for f in 0..<frames {
                            vDSP_vmul(s.baseAddress! + f * Self.hop, 1, w.baseAddress!, 1, frame, 1, vDSP_Length(N))
                            frame.withMemoryRebound(to: DSPComplex.self, capacity: H) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(H))
                            }
                            vDSP_DFT_Execute(setup, inRe, inIm, outRe, outIm)
                            // Packed output: DC in outRe[0], Nyquist in outIm[0]; bins 1..<960 are ordinary pairs.
                            let rr = r.baseAddress! + f * B, ii = i.baseAddress! + f * B
                            rr[0] = outRe[0]
                            rr[H] = outIm[0]
                            (rr + 1).update(from: outRe + 1, count: H - 1)
                            (ii + 1).update(from: outIm + 1, count: H - 1)
                        }
                    }
                }
            }
        }
        return (re, im, frames)
    }

    /// Inverse of `stft`: inverse real DFT per frame, window, overlap-add, divide by `sum w^2`. The result has exactly
    /// `length` samples: truncated if shorter than the frames cover, zero-padded if longer (torch.istft with `length`
    /// does the same). Zero frames give `length` zeros (torch raises).
    public func istft(re: [Float], im: [Float], frames: Int, length: Int) -> [Float] {
        precondition(frames >= 0 && length >= 0, "negative frames or length")
        precondition(re.count == frames * Self.bins && im.count == re.count,
                     "spectrum is not [\(frames), \(Self.bins)]: re \(re.count), im \(im.count)")
        var out = [Float](repeating: 0, count: length)
        guard frames > 0, length > 0 else { return out }
        let N = Self.fftSize, H = Self.half, B = Self.bins
        let covered = Self.coveredLength(frames: frames)

        var acc = [Float](repeating: 0, count: covered)
        let setup = Self.requireSetup(.INVERSE)
        defer { vDSP_DFT_DestroySetup(setup) }
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: N)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4 * H)
        defer { frame.deallocate(); scratch.deallocate() }
        let inRe = scratch, inIm = scratch + H, outRe = scratch + 2 * H, outIm = scratch + 3 * H

        acc.withUnsafeMutableBufferPointer { a in
            re.withUnsafeBufferPointer { r in
                im.withUnsafeBufferPointer { i in
                    Self.window.withUnsafeBufferPointer { w in
                        var split = DSPSplitComplex(realp: outRe, imagp: outIm)
                        for f in 0..<frames {
                            let rr = r.baseAddress! + f * B, ii = i.baseAddress! + f * B
                            // Pack: DC in re[0], Nyquist in im[0]. The imaginary parts of bins 0 and 960 are ignored,
                            // as a real-output inverse (torch's irfft) does.
                            inRe[0] = rr[0]
                            inIm[0] = rr[H]
                            (inRe + 1).update(from: rr + 1, count: H - 1)
                            (inIm + 1).update(from: ii + 1, count: H - 1)
                            vDSP_DFT_Execute(setup, inRe, inIm, outRe, outIm)  // N x the signal
                            frame.withMemoryRebound(to: DSPComplex.self, capacity: H) {
                                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(H))
                            }
                            let p = a.baseAddress! + f * Self.hop
                            vDSP_vma(frame, 1, w.baseAddress!, 1, p, 1, p, 1, vDSP_Length(N))
                        }
                    }
                }
            }
        }

        // y = acc / (N * sum w^2): the 1/N of the unnormalised inverse DFT is folded into the denominator.
        var den = Self.envelope(frames: frames)
        var n = Float(N)
        vDSP_vsmul(den, 1, &n, &den, 1, vDSP_Length(covered))
        let m = min(length, covered)
        acc.withUnsafeBufferPointer { a in
            den.withUnsafeBufferPointer { d in
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_vdiv(d.baseAddress!, 1, a.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(m))
                }
            }
        }
        return out
    }

    /// `re *= mask`, `im *= mask` for a real mask `[frames, 961]`: scales magnitude, keeps phase.
    public func apply(mask: [Float], re: inout [Float], im: inout [Float]) {
        precondition(mask.count == re.count && mask.count == im.count,
                     "mask \(mask.count), re \(re.count), im \(im.count) must be the same size")
        let n = vDSP_Length(mask.count)
        vDSP_vmul(re, 1, mask, 1, &re, 1, n)
        vDSP_vmul(im, 1, mask, 1, &im, 1, n)
    }
}
