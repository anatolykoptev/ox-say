import CoreML
import Foundation
import Metal

/// Features `[frames, 180]` row-major in, mask `[frames, 961]` row-major out.
public protocol MaskPredicting {
    func mask(features: [Float], frames: Int) throws -> [Float]
}

/// What loading and using the model cost, for the CLI and the UI («Готовлю модель…» covers `firstPredictionSeconds`).
public struct ModelStats: Equatable {
    /// Reading the files, building the Core ML model object.
    public var loadSeconds: Double = 0
    /// The first prediction of a load, which is the known-answer run: the GPU compiles its kernels here (about 7 s on
    /// an M5 Pro; the second load in the same process showed whether that compile is cached).
    public var firstPredictionSeconds: Double = 0
    public var knownAnswerMSE: Double = 0
    public var knownAnswerP999: Double = 0
    public var knownAnswerMaxAbs: Double = 0
    /// Predictions after the known-answer run, and the time they took.
    public var predictions = 0
    public var predictionSeconds: Double = 0
    /// The GPU Core ML was pointed at: the plan's discrete GPU, else the system default GPU when the units include the GPU.
    /// nil on cpuOnly and for a stub backend. Lets the CLI, the UI and probes say which device ran.
    public var deviceName: String?
    public var deviceRegistryID: UInt64?
    /// "cpuAndGPU" or "cpuOnly".
    public var computeUnits: String?
}

/// The MossFormer2_SE_48K mask network on Core ML. Loading checks, in order: `manifest.json` and `config.json` against
/// the engine's constants, `reference_window.bin`, the compiled model's own I/O description, and finally the
/// known-answer run: the stored features go through the model and the mask must match the stored PyTorch mask under the
/// converter's rule. A mismatch refuses the model, so a future macOS that mis-runs it cannot produce silent garbage.
public final class MaskModel: MaskPredicting {
    public static let directoryName = "mossformer2-se-48k"
    public static let modelFile = "MossFormer2_SE_48K.mlmodelc"
    public static let inputName = "features"
    public static let outputName = "mask"

    private let backend: MaskPredicting
    public private(set) var stats = ModelStats()

    /// The compute units the Core ML model object reports, nil for a stub backend.
    var configuredComputeUnits: MLComputeUnits? { (backend as? CoreMLBackend)?.configuredComputeUnits }

    /// `modelsDir` holds `mossformer2-se-48k/` (the layout `fetch-models.sh --clean-only` writes under `<dest>/clean`).
    public convenience init(modelsDir: URL, plan: ComputePlan = ComputeChoice.current()) throws {
        try self.init(modelsDir: modelsDir, loadBackend: { try CoreMLBackend(compiledURL: $0, plan: plan) })
    }

    /// The load path with the Core ML object replaced: tests drive the contract and known-answer checks through it.
    init(modelsDir: URL, loadBackend: (URL) throws -> MaskPredicting) throws {
        let clock = ContinuousClock()
        let t0 = clock.now
        let dir = modelsDir.appendingPathComponent(Self.directoryName)
        let compiled = dir.appendingPathComponent(Self.modelFile)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: compiled.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.models("missing", detail: "The voice-cleanup model is not installed (\(Self.modelFile) was not found); download it first.")
        }
        try ModelContract.validate(manifest: ModelContract.read(dir.appendingPathComponent("manifest.json"), reason: "manifest"),
                                   config: ModelContract.read(dir.appendingPathComponent("config.json"), reason: "config"))
        let reference = try ReferenceWindow.read(dir.appendingPathComponent("reference_window.bin"))
        let backend = try loadBackend(compiled)
        self.backend = backend
        stats.loadSeconds = (clock.now - t0).seconds
        if let core = backend as? CoreMLBackend {
            stats.deviceName = core.device?.name
            stats.deviceRegistryID = core.device?.registryID
            stats.computeUnits = core.configuredComputeUnits == .cpuOnly ? "cpuOnly" : "cpuAndGPU"
        }

        let t1 = clock.now
        let answer = try Self.run(backend, features: reference.features, frames: ModelContract.frames)
        stats.firstPredictionSeconds = (clock.now - t1).seconds
        let measured = KnownAnswer.measure(got: answer, want: reference.mask)
        stats.knownAnswerMSE = measured.mse
        stats.knownAnswerP999 = measured.p999
        stats.knownAnswerMaxAbs = measured.maxAbs
        guard KnownAnswer.passes(measured) else {
            throw Failure.models("known_answer", detail:
                "The voice-cleanup model gave a wrong answer on this Mac, so nothing was cleaned "
                + "(mean squared error \(Self.format(measured.mse)) against a limit of \(Self.format(KnownAnswer.mseLimit)), "
                + "99.9th-percentile error \(Self.format(measured.p999)) against \(Self.format(KnownAnswer.p999Limit)); "
                + "macOS \(Self.osVersion())).")
        }
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func format(_ v: Double) -> String { v.isFinite ? String(format: "%.3g", v) : "not a number" }

    private static func run(_ backend: MaskPredicting, features: [Float], frames: Int) throws -> [Float] {
        do { return try backend.mask(features: features, frames: frames) } catch let f as Failure { throw f } catch {
            throw Failure.processing("predict", detail: "The voice-cleanup model failed: \(error.localizedDescription)")
        }
    }

    public func mask(features: [Float], frames: Int) throws -> [Float] {
        guard frames == ModelContract.frames, features.count == frames * ModelContract.features else {
            throw Failure.processing("features_shape", detail: "The model takes \(ModelContract.frames) frames of \(ModelContract.features) features; got \(features.count) values for \(frames) frames.")
        }
        let t0 = ContinuousClock.now
        let out = try Self.run(backend, features: features, frames: frames)
        stats.predictions += 1
        stats.predictionSeconds += (ContinuousClock.now - t0).seconds
        return out
    }
}

/// The real Core ML model. Everything that touches `MLMultiArray` memory is here and checks its bounds.
final class CoreMLBackend: MaskPredicting {
    let model: MLModel
    /// The GPU the configuration names (or the system default one when the units include the GPU), nil on cpuOnly.
    let device: MTLDevice?

    /// `expected` is the I/O contract the compiled model must declare; only tests pass anything but `.engine`.
    init(compiledURL: URL, plan: ComputePlan, expected: IOSpec = .engine) throws {
        let cfg = try Self.configuration(plan: plan, devices: plan.discreteGPUIndex == nil ? [] : MTLCopyAllDevices())
        device = cfg.computeUnits == .cpuOnly ? nil : (cfg.preferredMetalDevice ?? MTLCreateSystemDefaultDevice())
        do { model = try MLModel(contentsOf: compiledURL, configuration: cfg) } catch {
            throw Failure.models("load", detail: "The voice-cleanup model could not be loaded: \(error.localizedDescription)")
        }
        try IOSpec.verify(IOSpec(model.modelDescription), against: expected)
    }

    /// The Core ML configuration for a plan: the plan's units (never `.all`, never the ANE) and, for a discrete-GPU
    /// plan, that device (it must still be there and still be neither low-power nor removable).
    static func configuration(plan: ComputePlan, devices: [MTLDevice]) throws -> MLModelConfiguration {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = plan.units
        if let i = plan.discreteGPUIndex {
            guard i >= 0, i < devices.count, !devices[i].isLowPower, !devices[i].isRemovable else {
                throw Failure.models("gpu", detail: "The graphics card chosen for voice cleanup is no longer available.")
            }
            cfg.preferredMetalDevice = devices[i]
        }
        return cfg
    }

    /// What the loaded model was actually configured with (the real-model test compares it with the plan).
    var configuredComputeUnits: MLComputeUnits { model.configuration.computeUnits }

    func mask(features: [Float], frames: Int) throws -> [Float] {
        let input = try Self.makeInput(features, frames: frames)
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [MaskModel.inputName: MLFeatureValue(multiArray: input)]))
        } catch {
            throw Failure.processing("predict", detail: "The voice-cleanup model failed: \(error.localizedDescription)")
        }
        guard let array = result.featureValue(for: MaskModel.outputName)?.multiArrayValue else {
            throw Failure.processing("mask_missing", detail: "The voice-cleanup model returned no mask.")
        }
        return try Self.readMask(array, frames: frames)
    }

    static func makeInput(_ features: [Float], frames: Int) throws -> MLMultiArray {
        let n = ModelContract.features
        precondition(features.count == frames * n, "caller checks the size")
        let array: MLMultiArray
        do { array = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: n)], dataType: .float32) } catch {
            throw Failure.processing("input_alloc", detail: "Not enough memory for the voice-cleanup model.")
        }
        // The closure must not throw: a throwing closure handed to CoreML's rethrowing `withUnsafeMutableBytes` leaves the
        // swifterror register non-zero on its normal return on x86_64 release builds, and XCTest's error observer then
        // crashes bridging a junk pointer. Validate inside, report with a plain Bool, throw outside.
        let filled: Bool = array.withUnsafeMutableBytes { raw, strides in
            let s = strides
            guard s.count == 3, s[2] >= 1, s[1] >= 0, ((frames - 1) * s[1] + (n - 1) * s[2] + 1) * 4 <= raw.count else { return false }
            let p = raw.bindMemory(to: Float.self)
            features.withUnsafeBufferPointer { f in
                if s[2] == 1 && s[1] == n {
                    _ = memcpy(p.baseAddress!, f.baseAddress!, frames * n * 4)
                } else {
                    for t in 0..<frames { for b in 0..<n { p[t * s[1] + b * s[2]] = f[t * n + b] } }
                }
            }
            return true
        }
        guard filled else { throw Failure.processing("input_strides", detail: "Core ML allocated an input array this engine cannot fill.") }
        return array
    }

    /// The mask as a dense `[frames, 961]` row-major array, whatever the array's element type and strides: Core ML on
    /// the GPU may pad rows, and reading as if contiguous would shear every row.
    static func readMask(_ a: MLMultiArray, frames: Int) throws -> [Float] {
        let bins = FeatureConfig.bins
        guard a.shape.map(\.intValue) == [1, frames, bins] else {
            throw Failure.processing("mask_shape", detail: "The voice-cleanup model returned a mask of shape \(a.shape.map(\.intValue)), not [1, \(frames), \(bins)].")
        }
        let strides = a.strides.map(\.intValue)
        let rowStride = strides[1], binStride = strides[2]
        guard binStride >= 1, rowStride >= 0 else {
            throw Failure.processing("mask_strides", detail: "The voice-cleanup model returned a mask with strides this engine cannot read.")
        }
        let lastIndex = (frames - 1) * rowStride + (bins - 1) * binStride
        let type = a.dataType
        // Non-throwing closure, see makeInput: the outcome travels as a Result and is unwrapped outside.
        let outcome: Result<[Float], Failure> = a.withUnsafeBytes { raw in
            func gather<T>(_ t: T.Type, _ convert: (T) -> Float) -> Result<[Float], Failure> {
                // `raw.count` is the span Core ML reports for this array; the strides must fit inside it.
                guard (lastIndex + 1) * MemoryLayout<T>.stride <= raw.count else {
                    return .failure(Failure.processing("mask_strides", detail: "The voice-cleanup model returned a mask whose strides reach past its memory."))
                }
                let p = raw.bindMemory(to: T.self)
                var out = [Float](repeating: 0, count: frames * bins)
                for t in 0..<frames { for b in 0..<bins { out[t * bins + b] = convert(p[t * rowStride + b * binStride]) } }
                return .success(out)
            }
            switch type {
            case .float32: return gather(Float.self) { $0 }
            case .double: return gather(Double.self) { Float($0) }
            #if arch(arm64)
            case .float16: return gather(Float16.self) { Float($0) }
            #endif
            default: return .failure(Failure.processing("mask_dtype", detail: "The voice-cleanup model returned a mask of an unsupported type."))
            }
        }
        return try outcome.get()
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// The shape and element type of one multi-array feature. An empty `shape` means the model leaves it unspecified.
struct ArraySpec: Equatable {
    var shape: [Int]
    var dtype: MLMultiArrayDataType
}

/// A compiled model's declared inputs and outputs, as plain values so the check is a pure function.
struct IOSpec: Equatable {
    var inputs: [String: ArraySpec]
    var outputs: [String: ArraySpec]

    /// What the engine feeds and reads: float32 `features [1, 2496, 180]` in, float32 `mask [1, 2496, 961]` out.
    static let engine = IOSpec(
        inputs: [MaskModel.inputName: ArraySpec(shape: [1, ModelContract.frames, ModelContract.features], dtype: .float32)],
        outputs: [MaskModel.outputName: ArraySpec(shape: [1, ModelContract.frames, FeatureConfig.bins], dtype: .float32)])

    /// A non-multi-array feature is left out, so it shows up as a missing name.
    init(_ d: MLModelDescription) {
        func specs(_ m: [String: MLFeatureDescription]) -> [String: ArraySpec] {
            m.compactMapValues { f in f.multiArrayConstraint.map { ArraySpec(shape: $0.shape.map(\.intValue), dtype: $0.dataType) } }
        }
        self.init(inputs: specs(d.inputDescriptionsByName), outputs: specs(d.outputDescriptionsByName))
    }

    init(inputs: [String: ArraySpec], outputs: [String: ArraySpec]) {
        self.inputs = inputs
        self.outputs = outputs
    }

    /// Throws `Failure.models` with reason "names", "shape" or "dtype". An unspecified (empty) shape is accepted
    /// wherever the expectation has one; an element type is never left open.
    static func verify(_ actual: IOSpec, against expected: IOSpec = .engine) throws {
        func bad(_ reason: String, _ what: String) -> Failure {
            Failure.models(reason, detail: "The compiled voice-cleanup model does not match this engine (\(what)); download the model again.")
        }
        guard Set(actual.inputs.keys) == Set(expected.inputs.keys) else { throw bad("names", "input names \(actual.inputs.keys.sorted())") }
        guard Set(actual.outputs.keys) == Set(expected.outputs.keys) else { throw bad("names", "output names \(actual.outputs.keys.sorted())") }
        for (kind, a, e) in [("input", actual.inputs, expected.inputs), ("output", actual.outputs, expected.outputs)] {
            for (name, want) in e {
                let got = a[name]!
                guard got.dtype == want.dtype else { throw bad("dtype", "\(kind) \(name) is element type \(got.dtype.rawValue), not \(want.dtype.rawValue)") }
                guard got.shape == want.shape || (kind == "output" && got.shape.isEmpty) else { throw bad("shape", "\(kind) \(name) has shape \(got.shape)") }
            }
        }
    }
}
