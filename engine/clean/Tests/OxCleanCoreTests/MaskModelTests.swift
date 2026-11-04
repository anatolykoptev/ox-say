import CoreML
import Metal
import XCTest
@testable import OxCleanCore

/// Everything about loading and checking the model that needs no weights: the units table, the contract against the
/// real manifest/config, the known-answer refusal, and reading a Core ML output with arbitrary strides.
final class MaskModelTests: XCTestCase {
    // MARK: compute units (decisions 5 and 8)

    private let discrete = GPUDescription(isLowPower: false, isRemovable: false)
    private let integrated = GPUDescription(isLowPower: true, isRemovable: false)
    private let egpu = GPUDescription(isLowPower: false, isRemovable: true)

    /// The stats line (and the speed probe behind it) can only catch a plan that drifted to `.all` or the Neural Engine
    /// if the name it prints is the real one: a binary cpuOnly/cpuAndGPU label would call both "cpuAndGPU".
    func testEveryComputeUnitIsNamedForWhatItIs() {
        XCTAssertEqual(ModelStats.name(of: .cpuOnly), "cpuOnly")
        XCTAssertEqual(ModelStats.name(of: .cpuAndGPU), "cpuAndGPU")
        XCTAssertEqual(ModelStats.name(of: .cpuAndNeuralEngine), "cpuAndNeuralEngine")
        XCTAssertEqual(ModelStats.name(of: .all), "all")
    }

    func testTheComputeUnitsTable() {
        typealias Row = (String, CPUArchitecture, [GPUDescription], String?, MLComputeUnits, Int?)
        let rows: [Row] = [
            ("arm64", .arm64, [discrete], nil, .cpuAndGPU, nil),
            ("arm64, no devices listed", .arm64, [], nil, .cpuAndGPU, nil),
            ("Intel with a discrete GPU after the iGPU", .x86_64, [integrated, discrete], nil, .cpuAndGPU, 1),
            ("Intel with a discrete GPU first", .x86_64, [discrete, integrated], nil, .cpuAndGPU, 0),
            ("Intel, iGPU only", .x86_64, [integrated], nil, .cpuOnly, nil),
            ("Intel, no Metal device", .x86_64, [], nil, .cpuOnly, nil),
            ("Intel, only an eGPU", .x86_64, [integrated, egpu], nil, .cpuOnly, nil),
            ("Intel, eGPU before the dGPU", .x86_64, [egpu, integrated, discrete], nil, .cpuAndGPU, 2),
            // OX_CLEAN_COMPUTE_UNITS may only lower the choice.
            // arm64 has no cpuOnly option (decision 5: the CPU fp16 runtime defect), so the knob is ignored there.
            ("arm64 ignores cpuOnly", .arm64, [discrete], "cpuOnly", .cpuAndGPU, nil),
            ("Intel dGPU lowered to cpuOnly", .x86_64, [discrete], "cpuOnly", .cpuOnly, nil),
            ("arm64 cpuAndGPU is no change", .arm64, [], "cpuAndGPU", .cpuAndGPU, nil),
            ("Intel iGPU cannot be raised to cpuAndGPU", .x86_64, [integrated], "cpuAndGPU", .cpuOnly, nil),
            ("the ANE is never accepted", .arm64, [], "cpuAndNeuralEngine", .cpuAndGPU, nil),
            ("all is never accepted", .arm64, [], "all", .cpuAndGPU, nil),
            ("junk is ignored", .x86_64, [integrated], "banana", .cpuOnly, nil),
        ]
        for (name, arch, gpus, override, units, index) in rows {
            let plan = ComputeChoice.plan(architecture: arch, gpus: gpus, override: override)
            XCTAssertEqual(plan.units.rawValue, units.rawValue, name)
            XCTAssertEqual(plan.discreteGPUIndex, index, name)
            XCTAssertNotEqual(plan.units, .all, name)
            XCTAssertNotEqual(plan.units, .cpuAndNeuralEngine, name)
        }
    }

    func testTheConfigurationCarriesThePlansUnitsAndDevice() throws {
        // The call-site guarantee: whatever the plan says is what Core ML is configured with, never .all or the ANE.
        for units in [MLComputeUnits.cpuAndGPU, .cpuOnly] {
            let cfg = try CoreMLBackend.configuration(plan: ComputePlan(units: units, discreteGPUIndex: nil), devices: [])
            XCTAssertEqual(cfg.computeUnits.rawValue, units.rawValue)
            XCTAssertNil(cfg.preferredMetalDevice)
        }
        // The plan for this machine's real devices (the index must fit the real list, whatever order the OS gives them).
        let real = MTLCopyAllDevices()
        let described = real.map { GPUDescription(isLowPower: $0.isLowPower, isRemovable: $0.isRemovable) }
        for (arch, gpus, devices) in [(CPUArchitecture.arm64, [GPUDescription](), [MTLDevice]()), (.x86_64, described, real)] {
            let plan = ComputeChoice.plan(architecture: arch, gpus: gpus, override: nil)
            let cfg = try CoreMLBackend.configuration(plan: plan, devices: devices)
            XCTAssertEqual(cfg.computeUnits.rawValue, plan.units.rawValue)
            XCTAssertNotEqual(cfg.computeUnits, .all)
            XCTAssertNotEqual(cfg.computeUnits, .cpuAndNeuralEngine)
            if let i = plan.discreteGPUIndex {
                XCTAssertEqual(cfg.preferredMetalDevice?.registryID, real[i].registryID)
                XCTAssertFalse(real[i].isLowPower || real[i].isRemovable)
            }
        }
    }

    func testThePreferredMetalDeviceIsTheChosenOneAndMustStillQualify() throws {
        let devices = MTLCopyAllDevices()
        guard let i = devices.firstIndex(where: { !$0.isLowPower && !$0.isRemovable }) else { throw XCTSkip("no discrete or Apple GPU here") }
        let cfg = try CoreMLBackend.configuration(plan: ComputePlan(units: .cpuAndGPU, discreteGPUIndex: i), devices: devices)
        XCTAssertEqual(cfg.preferredMetalDevice?.registryID, devices[i].registryID)
        XCTAssertEqual(cfg.computeUnits.rawValue, MLComputeUnits.cpuAndGPU.rawValue)
        for bad in [devices.count, -1] {
            XCTAssertThrowsError(try CoreMLBackend.configuration(plan: ComputePlan(units: .cpuAndGPU, discreteGPUIndex: bad), devices: devices)) {
                XCTAssertEqual(($0 as? Failure)?.reason, "gpu")
            }
        }
        if let j = devices.firstIndex(where: { $0.isLowPower || $0.isRemovable }) {
            XCTAssertThrowsError(try CoreMLBackend.configuration(plan: ComputePlan(units: .cpuAndGPU, discreteGPUIndex: j), devices: devices)) {
                XCTAssertEqual(($0 as? Failure)?.reason, "gpu")
            }
        }
    }

    // MARK: the compiled model's declared I/O (pure over plain values)

    func testTheDeclaredIOMustMatchTheEngine() throws {
        XCTAssertNoThrow(try IOSpec.verify(.engine))
        let io = IOSpec.engine
        let inShape = [1, 2496, 180], outShape = [1, 2496, 961]
        func edit(_ f: (inout IOSpec) -> Void) -> IOSpec { var c = io; f(&c); return c }
        let ok: [(String, IOSpec)] = [("output shape left open", edit { $0.outputs["mask"] = ArraySpec(shape: [], dtype: .float32) })]
        for (name, spec) in ok { XCTAssertNoThrow(try IOSpec.verify(spec), name) }
        let bad: [(String, IOSpec, String)] = [
            ("input renamed", edit { $0.inputs = ["x": ArraySpec(shape: inShape, dtype: .float32)] }, "names"),
            ("extra input", edit { $0.inputs["extra"] = ArraySpec(shape: [1], dtype: .float32) }, "names"),
            ("no input", edit { $0.inputs = [:] }, "names"),
            ("output renamed", edit { $0.outputs = ["y": ArraySpec(shape: outShape, dtype: .float32)] }, "names"),
            ("input shape", edit { $0.inputs["features"] = ArraySpec(shape: [1, 496, 180], dtype: .float32) }, "shape"),
            ("input shape left open", edit { $0.inputs["features"] = ArraySpec(shape: [], dtype: .float32) }, "shape"),
            ("output shape", edit { $0.outputs["mask"] = ArraySpec(shape: [1, 2496, 960], dtype: .float32) }, "shape"),
            ("input float16", edit { $0.inputs["features"] = ArraySpec(shape: inShape, dtype: .float16) }, "dtype"),
            ("output float16", edit { $0.outputs["mask"] = ArraySpec(shape: outShape, dtype: .float16) }, "dtype"),
            ("output double", edit { $0.outputs["mask"] = ArraySpec(shape: outShape, dtype: .double) }, "dtype"),
            ("output dtype with an open shape", edit { $0.outputs["mask"] = ArraySpec(shape: [], dtype: .float16) }, "dtype"),
        ]
        for (name, spec, reason) in bad {
            XCTAssertThrowsError(try IOSpec.verify(spec), name) {
                XCTAssertEqual(($0 as? Failure)?.reason, reason, name)
                XCTAssertEqual(($0 as? Failure)?.exitCode, .models, name)
            }
        }
    }

    // MARK: KnownAnswer.measure against numpy

    func testMeasureMatchesNumpysQuantile() throws {
        // 100,001 Gaussian values (and then the first 50) (SplitMix64 seed 5, the stream of gen_golden_e2e.gauss) against zeros. Expected values
        // from: np.quantile(np.abs(x.astype(np.float64)), 0.999), (e**2).mean(), e.max() on the float32 array,
        // with engine/clean/convert/.venv/bin/python -B (numpy 1.26.4).
        var noise = GaussianNoise(seed: 5)
        let got = (0..<100_001).map { _ in noise.next() }
        let s = KnownAnswer.measure(got: got, want: [Float](repeating: 0, count: got.count))
        XCTAssertEqual(s.p999, 3.307770013809204, accuracy: 1e-5)
        XCTAssertEqual(s.mse, 1.0035559845568813, accuracy: 1e-6)
        XCTAssertEqual(s.maxAbs, 4.515058994293213, accuracy: 1e-5)
        // 50 values: the 99.9th percentile falls between the two largest (position 48.951), so interpolation matters.
        var small = GaussianNoise(seed: 5)
        let few = (0..<50).map { _ in small.next() }
        let t = KnownAnswer.measure(got: few, want: [Float](repeating: 0, count: 50))
        XCTAssertEqual(t.p999, 2.072662753343582, accuracy: 1e-5)
        XCTAssertEqual(t.mse, 0.9712980999852213, accuracy: 1e-6)
    }

    func testTheSpeedFloorFollowsThePlan() {
        let gpu = ComputePlan(units: .cpuAndGPU, discreteGPUIndex: nil), cpu = ComputePlan(units: .cpuOnly, discreteGPUIndex: nil)
        XCTAssertEqual(SpeedFloor.floor(for: gpu, architecture: .arm64), 50)
        XCTAssertEqual(SpeedFloor.floor(for: ComputePlan(units: .cpuAndGPU, discreteGPUIndex: 1), architecture: .x86_64), 5)
        XCTAssertEqual(SpeedFloor.floor(for: cpu, architecture: .x86_64), 2)
    }

    func testTheRealMachineGetsAPlanWithoutTheANE() {
        let plan = ComputeChoice.current(environment: [:])
        XCTAssertTrue(plan.units == .cpuAndGPU || plan.units == .cpuOnly)
    }

    // MARK: readMask: strides and dtype

    private func padded(frames: Int, rowStride: Int, type: MLMultiArrayDataType) throws -> (MLMultiArray, [Float]) {
        let bins = FeatureConfig.bins
        var want = [Float](repeating: 0, count: frames * bins)
        let (buffer, array): (UnsafeMutableRawPointer, MLMultiArray)
        switch type {
        case .float32:
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * rowStride)
            p.initialize(repeating: .nan, count: frames * rowStride)  // padding is poison
            for t in 0..<frames { for b in 0..<bins { let v = Float(t) * 0.001 + Float(b) * 1e-4; p[t * rowStride + b] = v; want[t * bins + b] = v } }
            buffer = UnsafeMutableRawPointer(p)
            array = try MLMultiArray(dataPointer: buffer, shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .float32,
                                     strides: [NSNumber(value: frames * rowStride), NSNumber(value: rowStride), 1], deallocator: { $0.deallocate() })
        case .double:
            let p = UnsafeMutablePointer<Double>.allocate(capacity: frames * rowStride)
            p.initialize(repeating: .nan, count: frames * rowStride)
            for t in 0..<frames { for b in 0..<bins { let v = Float(t) * 0.001 + Float(b) * 1e-4; p[t * rowStride + b] = Double(v); want[t * bins + b] = v } }
            buffer = UnsafeMutableRawPointer(p)
            array = try MLMultiArray(dataPointer: buffer, shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .double,
                                     strides: [NSNumber(value: frames * rowStride), NSNumber(value: rowStride), 1], deallocator: { $0.deallocate() })
        default:
            #if arch(arm64)
            let p = UnsafeMutablePointer<Float16>.allocate(capacity: frames * rowStride)
            p.initialize(repeating: .nan, count: frames * rowStride)
            for t in 0..<frames { for b in 0..<bins { let v = Float16(Float(t) * 0.001 + Float(b) * 1e-4); p[t * rowStride + b] = v; want[t * bins + b] = Float(v) } }
            buffer = UnsafeMutableRawPointer(p)
            array = try MLMultiArray(dataPointer: buffer, shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .float16,
                                     strides: [NSNumber(value: frames * rowStride), NSNumber(value: rowStride), 1], deallocator: { $0.deallocate() })
            #else
            throw XCTSkip("no Float16 on x86_64")
            #endif
        }
        return (array, want)
    }

    func testMakeInputCopiesTheFeaturesIntoACoreMLArray() throws {
        // Regression (Intel release): this call crashed XCTest's error observer when its closure was a throwing one.
        let f = (0..<(2496 * 180)).map { Float($0 % 977) }
        let a = try CoreMLBackend.makeInput(f, frames: 2496)
        XCTAssertEqual(a.shape.map(\.intValue), [1, 2496, 180])
        XCTAssertEqual(a.dataType, .float32)
        for (t, b) in [(0, 0), (0, 179), (1, 0), (1234, 77), (2495, 179)] {
            XCTAssertEqual(a[[0, t, b] as [NSNumber]].floatValue, f[t * 180 + b], "[\(t), \(b)]")
        }
    }

    func testReadMaskHonoursStridesThatPadTheLastDimension() throws {
        // Core ML on the GPU may pad rows (961 -> 976 or 1024 elements). Ignoring strides would shear every row.
        for stride in [961, 976, 1024] {
            let (a, want) = try padded(frames: 7, rowStride: stride, type: .float32)
            let got = try CoreMLBackend.readMask(a, frames: 7)
            XCTAssertEqual(got.count, want.count)
            if got.count == want.count { XCTAssertEqual(Fixture.maxAbsDiff(got, want), 0, "row stride \(stride)") }
        }
    }

    func testReadMaskReadsDoubleAndFloat16() throws {
        let (d, wantD) = try padded(frames: 5, rowStride: 976, type: .double)
        let gotD = try CoreMLBackend.readMask(d, frames: 5)
        XCTAssertEqual(Fixture.maxAbsDiff(gotD, wantD), 0, "double, padded rows")
        #if arch(arm64)
        let (h, wantH) = try padded(frames: 5, rowStride: 976, type: .float16)
        let gotH = try CoreMLBackend.readMask(h, frames: 5)
        XCTAssertEqual(Fixture.maxAbsDiff(gotH, wantH), 0, "float16, padded rows")
        #endif
    }

    func testReadMaskRefusesAWrongShapeAndAliasingStrides() throws {
        let (a, _) = try padded(frames: 7, rowStride: 961, type: .float32)
        XCTAssertThrowsError(try CoreMLBackend.readMask(a, frames: 8)) { XCTAssertEqual(($0 as? Failure)?.reason, "mask_shape") }
        // A zero bin stride would alias every bin of a row onto one element.
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 7 * 961)
        p.initialize(repeating: 0, count: 7 * 961)
        let bad = try MLMultiArray(dataPointer: p, shape: [1, 7, 961], dataType: .float32, strides: [NSNumber(value: 7 * 961), 961, 0], deallocator: { $0.deallocate() })
        XCTAssertThrowsError(try CoreMLBackend.readMask(bad, frames: 7)) { XCTAssertEqual(($0 as? Failure)?.reason, "mask_strides") }
    }

    // MARK: the model contract, against the real manifest.json and config.json

    private var testdata: URL { Fixture.dir }

    /// A models dir shaped like the download, with the real manifest/config (mutated by the caller), a stub
    /// `.mlmodelc` directory and a reference window built from `features` / `mask`.
    private func makeDir(manifest: (inout [String: Any]) -> Void = { _ in }, config: (inout [String: Any]) -> Void = { _ in },
                         features: [Float], mask: [Float], flipMaskByte: Int? = nil, withModel: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oxclean-models-\(UUID())")
        let dir = root.appendingPathComponent(MaskModel.directoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withModel { try FileManager.default.createDirectory(at: dir.appendingPathComponent(MaskModel.modelFile), withIntermediateDirectories: true) }
        func edit(_ name: String, _ f: (inout [String: Any]) -> Void) throws {
            var j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: testdata.appendingPathComponent(name))) as? [String: Any])
            f(&j)
            try JSONSerialization.data(withJSONObject: j).write(to: dir.appendingPathComponent(name.replacingOccurrences(of: "model_", with: "") ))
        }
        try edit("model_manifest.json", manifest)
        try edit("model_config.json", config)
        var bytes = Data("MF2REF01".utf8)
        for v in [UInt32(2496), 180, 961, 0] { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
        features.withUnsafeBytes { bytes.append(contentsOf: $0) }
        mask.withUnsafeBytes { bytes.append(contentsOf: $0) }
        if let i = flipMaskByte { bytes[24 + 4 * features.count + i] ^= 0x40 }
        try bytes.write(to: dir.appendingPathComponent("reference_window.bin"))
        return root
    }

    /// Features and a mask in [0.5, 1): the high byte of each mask value is 0x3F, so flipping bit 6 makes it about 1.7e38.
    private static let refFeatures: [Float] = (0..<(2496 * 180)).map { Float($0 % 211) * 0.01 }
    private static let refMask: [Float] = (0..<(2496 * 961)).map { 0.5 + Float($0 % 97) * 0.005 }

    private struct Lookup: MaskPredicting {
        var answer: [Float]
        var perturb: (inout [Float]) -> Void = { _ in }
        func mask(features: [Float], frames: Int) throws -> [Float] {
            guard features == MaskModelTests.refFeatures, frames == 2496 else { throw Failure.processing("not the reference window") }
            var a = answer
            perturb(&a)
            return a
        }
    }

    private func load(_ root: URL, _ backend: MaskPredicting) throws -> MaskModel {
        try MaskModel(modelsDir: root, loadBackend: { _ in backend })
    }

    func testAModelThatAnswersTheReferenceLoadsAndReportsTheKnownAnswerNumbers() throws {
        let root = try makeDir(features: Self.refFeatures, mask: Self.refMask)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = try load(root, Lookup(answer: Self.refMask))
        XCTAssertEqual(m.stats.knownAnswerMSE, 0)
        XCTAssertEqual(m.stats.knownAnswerP999, 0)
        XCTAssertGreaterThanOrEqual(m.stats.firstPredictionSeconds, 0)
    }

    func testOneFlippedByteInTheStoredMaskRefusesTheModel() throws {
        // Index 400 of the mask: value 0.5 + (400 % 97) * 0.005; its high byte is 0x3F, so the flip makes it about 1.7e38.
        let root = try makeDir(features: Self.refFeatures, mask: Self.refMask, flipMaskByte: 4 * 400 + 3)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try load(root, Lookup(answer: Self.refMask))) { e in
            let f = e as? Failure
            XCTAssertEqual(f?.reason, "known_answer")
            XCTAssertEqual(f?.exitCode, .models)
            let sentence = f?.detail ?? ""
            XCTAssertTrue(sentence.contains("macOS"), sentence)
            XCTAssertTrue(sentence.contains("mean squared error"), sentence)
            XCTAssertFalse(sentence.contains("\n"), sentence)
        }
    }

    func testTheKnownAnswerRuleIsMSEAndP999AndNoNaN() throws {
        let root = try makeDir(features: Self.refFeatures, mask: Self.refMask)
        defer { try? FileManager.default.removeItem(at: root) }
        func reason(_ perturb: @escaping (inout [Float]) -> Void) -> String? {
            do { _ = try load(root, Lookup(answer: Self.refMask, perturb: perturb)); return nil } catch { return (error as? Failure)?.reason }
        }
        // inside the rule
        XCTAssertNil(reason { for i in $0.indices { $0[i] += 0.005 } })           // mse 2.5e-5, p99.9 0.005
        // MSE over 1e-4 with every element off by 0.02
        XCTAssertEqual(reason { for i in $0.indices { $0[i] += 0.02 } }, "known_answer")
        // MSE under 1e-4 but 0.3 % of the elements off by 0.06: p99.9 is 0.06 > 0.05
        XCTAssertEqual(reason { for i in stride(from: 0, to: $0.count, by: 300) { $0[i] += 0.06 } }, "known_answer")
        // 0.05 % of the elements off by 0.9: p99.9 stays small and MSE is 4e-4 > 1e-4
        XCTAssertEqual(reason { for i in stride(from: 0, to: $0.count, by: 2000) { $0[i] += 0.9 } }, "known_answer")
        // one NaN
        XCTAssertEqual(reason { $0[12_345] = .nan }, "known_answer")
        // one Inf
        XCTAssertEqual(reason { $0[12_345] = .infinity }, "known_answer")
    }

    func testAModelWhoseOutputHasTheWrongSizeIsRefused() throws {
        let root = try makeDir(features: Self.refFeatures, mask: Self.refMask)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try load(root, Lookup(answer: Array(Self.refMask.dropLast())))) {
            XCTAssertEqual(($0 as? Failure)?.reason, "known_answer")
        }
    }

    func testAContractThatDisagreesWithTheEngineIsRefused() throws {
        typealias Edit = (inout [String: Any]) -> Void
        func nested(_ keys: [String], _ v: Any) -> Edit {
            return { j in
                func set(_ d: inout [String: Any], _ ks: ArraySlice<String>) {
                    if ks.count == 1 { d[ks.first!] = v; return }
                    var inner = d[ks.first!] as? [String: Any] ?? [:]
                    set(&inner, ks.dropFirst()); d[ks.first!] = inner
                }
                set(&j, keys[...])
            }
        }
        let manifest: [(String, Edit, String)] = [
            ("frames", nested(["frames"], 496), "shape"), ("features", nested(["features"], 181), "shape"),
            ("bins", nested(["bins"], 960), "shape"), ("window", nested(["window_samples"], 192_000), "window"),
            ("stride", nested(["stride_samples"], 144_000), "window"), ("xfade", nested(["xfade_samples"], 480), "window"),
            ("scale", nested(["scale"], 1), "scale"), ("input name", nested(["input"], "x"), "names"),
            ("output name", nested(["output"], "y"), "names"),
        ]
        let config: [(String, Edit, String)] = [
            ("input shape", nested(["input", "shape"], [1, 496, 180]), "shape"),
            ("output shape", nested(["output", "shape"], [1, 2496, 960]), "shape"),
            ("input dtype", nested(["input", "dtype"], "float16"), "dtype"),
            ("output dtype", nested(["output", "dtype"], "float64"), "dtype"),
            ("sample rate", nested(["audio", "sample_rate"], 16000), "audio"),
            ("fft", nested(["audio", "fft_len"], 1024), "audio"),
            ("dither", nested(["features", "dither"], 0.0), "dither"),
        ]
        for (name, edit, reason) in manifest + config {
            let isManifest = manifest.contains { $0.0 == name }
            let root = try makeDir(manifest: isManifest ? edit : { _ in }, config: isManifest ? { _ in } : edit,
                                   features: Self.refFeatures, mask: Self.refMask)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try load(root, Lookup(answer: Self.refMask)), name) {
                XCTAssertEqual(($0 as? Failure)?.reason, reason, name)
                XCTAssertEqual(($0 as? Failure)?.exitCode, .models, name)
            }
        }
    }

    // Fix round 7: only a genuinely absent model says "download it"; an unreadable folder, a symlink loop or a file where
    // the folder should be is exit 3 with another reason, so the daemon does not re-download for nothing.
    // Mutation: MaskModel.swift, the errno switch collapsed back to "missing" -> red.
    func testAModelsFolderThatCannotBeReadIsNotReportedAsNotInstalled() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oxclean-models-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let loop = base.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.path)
        for (name, dir) in [("a file", file), ("a symlink loop", loop)] {
            XCTAssertThrowsError(try load(dir, Lookup(answer: Self.refMask)), name) {
                let f = $0 as? Failure
                XCTAssertEqual(f?.reason, "unreadable", name)
                XCTAssertEqual(f?.exitCode, .models, name)
                XCTAssertFalse(f?.detail.contains("download") ?? true, name)
            }
        }
        let absent = base.appendingPathComponent("nothing-here")
        XCTAssertThrowsError(try load(absent, Lookup(answer: Self.refMask))) { XCTAssertEqual(($0 as? Failure)?.reason, "missing") }
    }

    func testMissingOrBrokenFilesAreRefusedAsModelFailures() throws {
        let noModel = try makeDir(features: Self.refFeatures, mask: Self.refMask, withModel: false)
        defer { try? FileManager.default.removeItem(at: noModel) }
        XCTAssertThrowsError(try load(noModel, Lookup(answer: Self.refMask))) { XCTAssertEqual(($0 as? Failure)?.reason, "missing") }

        let root = try makeDir(features: Self.refFeatures, mask: Self.refMask)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(MaskModel.directoryName)
        let ref = dir.appendingPathComponent("reference_window.bin")
        let good = try Data(contentsOf: ref)
        var badMagic = good; badMagic[0] = 0x58
        var badDims = good; badDims[8] = 0x10
        for (name, data) in [("magic", badMagic), ("dims", badDims), ("truncated", good.prefix(good.count - 4)), ("empty", Data())] {
            try data.write(to: ref)
            XCTAssertThrowsError(try load(root, Lookup(answer: Self.refMask)), name) { XCTAssertEqual(($0 as? Failure)?.reason, "reference", name) }
        }
        try Data("{".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try good.write(to: ref)
        XCTAssertThrowsError(try load(root, Lookup(answer: Self.refMask))) { XCTAssertEqual(($0 as? Failure)?.reason, "manifest") }
    }
}
