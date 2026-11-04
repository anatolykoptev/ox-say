import Foundation

#if !_endian(little)
#error("reference_window.bin is little-endian float32 and is copied as raw bytes")
#endif

/// `reference_window.bin`: one window of features and the PyTorch mask for them (convert/reference.py
/// `write_reference`): magic `MF2REF01`, `<4I` frames, features, bins, reserved, then float32 features
/// `[frames, 180]` and mask `[frames, 961]`.
struct ReferenceWindow {
    static let magic = Data("MF2REF01".utf8)
    static let headerBytes = 24
    var features: [Float]
    var mask: [Float]

    static func read(_ url: URL) throws -> ReferenceWindow {
        let frames = (Chunker.window - FeatureConfig.frameLength) / FeatureConfig.frameShift + 1
        let nf = 3 * FeatureConfig.mels, nb = FeatureConfig.bins
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw Failure.models("reference", detail: "The voice-cleanup model's reference file cannot be read: \(error.localizedDescription)")
        }
        func dim(_ at: Int) -> Int {
            Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }))
        }
        let expected = headerBytes + 4 * frames * (nf + nb)
        guard data.count == expected, data.prefix(8) == magic, dim(8) == frames, dim(12) == nf, dim(16) == nb else {
            throw Failure.models("reference", detail: "The voice-cleanup model's reference file is not the one this engine expects (\(data.count) bytes, wanted \(expected)).")
        }
        func floats(at offset: Int, count: Int) -> [Float] {
            [Float](unsafeUninitializedCapacity: count) { buf, n in
                data.withUnsafeBytes { raw in
                    _ = memcpy(buf.baseAddress!, raw.baseAddress! + offset, count * 4)
                }
                n = count
            }
        }
        return ReferenceWindow(features: floats(at: headerBytes, count: frames * nf),
                               mask: floats(at: headerBytes + 4 * frames * nf, count: frames * nb))
    }
}

/// manifest.json and config.json against the engine's own constants: a model that disagrees is refused before it is
/// loaded, so a wrong download can never produce a plausible-looking result.
enum ModelContract {
    static let frames = (Chunker.window - FeatureConfig.frameLength) / FeatureConfig.frameShift + 1  // 2496
    static let features = 3 * FeatureConfig.mels  // 180

    static func read(_ url: URL, reason: String) throws -> [String: Any] {
        do {
            guard let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return j
        } catch {
            throw Failure.models(reason, detail: "The voice-cleanup model's \(url.lastPathComponent) cannot be read; download the model again.")
        }
    }

    private static func int(_ any: Any?) -> Int? { (any as? NSNumber).map { Int(truncating: $0) } }
    private static func shape(_ any: Any?) -> [Int]? { (any as? [Any])?.compactMap { int($0) } }
    private static func wrong(_ reason: String, _ what: String) -> Failure {
        Failure.models(reason, detail: "The voice-cleanup model does not match this engine (\(what)); download the model again.")
    }

    static func validate(manifest m: [String: Any], config c: [String: Any]) throws {
        guard int(m["frames"]) == frames, int(m["features"]) == features, int(m["bins"]) == FeatureConfig.bins else { throw wrong("shape", "manifest frames/features/bins") }
        guard int(m["window_samples"]) == Chunker.window, int(m["stride_samples"]) == Chunker.stride, int(m["xfade_samples"]) == Chunker.crossfade else {
            throw wrong("window", "window, stride or crossfade")
        }
        guard int(m["scale"]) == Int(FeatureConfig.scale) else { throw wrong("scale", "waveform scale") }
        guard m["input"] as? String == MaskModel.inputName, m["output"] as? String == MaskModel.outputName else { throw wrong("names", "input or output name") }
        guard let input = c["input"] as? [String: Any], let output = c["output"] as? [String: Any] else { throw wrong("shape", "config input/output") }
        guard input["name"] as? String == MaskModel.inputName, output["name"] as? String == MaskModel.outputName else { throw wrong("names", "config input or output name") }
        guard shape(input["shape"]) == [1, frames, features], shape(output["shape"]) == [1, frames, FeatureConfig.bins] else { throw wrong("shape", "config input/output shape") }
        guard input["dtype"] as? String == "float32", output["dtype"] as? String == "float32" else { throw wrong("dtype", "config input/output dtype") }
        guard let a = c["audio"] as? [String: Any], int(a["sample_rate"]) == FeatureConfig.sampleRate, int(a["fft_len"]) == FeatureConfig.frameLength,
              int(a["win_len"]) == FeatureConfig.frameLength, int(a["hop"]) == FeatureConfig.frameShift, int(a["scale"]) == Int(FeatureConfig.scale) else {
            throw wrong("audio", "sample rate, FFT or hop")
        }
        guard let f = c["features"] as? [String: Any], int(f["num_mel_bins"]) == FeatureConfig.mels else { throw wrong("shape", "mel bins") }
        // Sigma 1.0 is what the engine draws (Cleaner.ditherSeed); a model trained or converted for another value would be fed the wrong features.
        guard (f["dither"] as? NSNumber)?.doubleValue == 1.0, (m["dither"] as? NSNumber)?.doubleValue == 1.0 else { throw wrong("dither", "dither sigma") }
    }
}

/// Decision 10: the rule the converter gates on (`known_answer_ok` in convert/verify.py), applied after every load.
enum KnownAnswer {
    static let mseLimit = 1e-4
    static let p999Limit = 0.05

    struct Stats: Equatable {
        var mse: Double
        var p999: Double
        var maxAbs: Double
    }

    /// numpy's default `quantile`: linear interpolation at `q * (n - 1)` of the sorted values. Any NaN or Inf (in either
    /// mask), or a size mismatch, gives NaN statistics, which `passes` rejects.
    static func measure(got: [Float], want: [Float]) -> Stats {
        let bad = Stats(mse: .nan, p999: .nan, maxAbs: .nan)
        guard got.count == want.count, !got.isEmpty, got.allSatisfy(\.isFinite), want.allSatisfy(\.isFinite) else { return bad }
        var err = [Double](repeating: 0, count: got.count)
        var sum = 0.0
        for i in 0..<got.count {
            let d = abs(Double(got[i]) - Double(want[i]))
            err[i] = d
            sum += d * d
        }
        err.sort()
        let pos = 0.999 * Double(err.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, err.count - 1)
        let p999 = err[lo] + (pos - Double(lo)) * (err[hi] - err[lo])
        return Stats(mse: sum / Double(err.count), p999: p999, maxAbs: err[err.count - 1])
    }

    static func passes(_ s: Stats) -> Bool {
        s.mse.isFinite && s.p999.isFinite && s.maxAbs.isFinite && s.mse <= mseLimit && s.p999 <= p999Limit
    }
}
