// probe.swift -- one compute-unit configuration per process (so the peak footprint belongs to that configuration).
// usage: probe MODEL.mlmodelc FEATS.f32 UNITS ITERS [OUT_MASK.f32]
//   UNITS = cpuOnly | cpuAndGPU | cpuAndNeuralEngine | all     FEATS = raw float32 [1,2496,180]
//   WIN_S / NEW_S env vars set the real-time factors' window/stride basis (default 20 s / 15 s).
// prints one JSON line: op shares per device (MLComputePlan), load time, first prediction, median of ITERS, peak footprint.
import Foundation
import CoreML

func footprint() -> (cur: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard r == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1073741824.0, Double(info.ledger_phys_footprint_peak) / 1073741824.0)
}
func now() -> Double { var t = timespec(); clock_gettime(CLOCK_MONOTONIC, &t); return Double(t.tv_sec) + Double(t.tv_nsec) * 1e-9 }

let a = CommandLine.arguments
guard a.count >= 5 else { FileHandle.standardError.write("usage: probe MODEL FEATS UNITS ITERS [OUT]\n".data(using: .utf8)!); exit(2) }
let modelURL = URL(fileURLWithPath: a[1])
let featData = try! Data(contentsOf: URL(fileURLWithPath: a[2]))
let units: MLComputeUnits
switch a[3] {
case "cpuOnly": units = .cpuOnly
case "cpuAndGPU": units = .cpuAndGPU
case "cpuAndNeuralEngine": units = .cpuAndNeuralEngine
case "all": units = .all
default: FileHandle.standardError.write("bad units\n".data(using: .utf8)!); exit(2)
}
let iters = Int(a[4]) ?? 20
let cfg = MLModelConfiguration(); cfg.computeUnits = units
if #available(macOS 15.0, *), let sp = ProcessInfo.processInfo.environment["SPEC"] {
    var h = MLOptimizationHints()
    if sp == "fast" { h.specializationStrategy = .fastPrediction } else if sp == "default" { h.specializationStrategy = .default }
    cfg.optimizationHints = h
}

// ---- op shares (MLComputePlan) ----
var shares: [String: Int] = ["ane": 0, "gpu": 0, "cpu": 0, "unknown": 0]
var totalOps = 0
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let plan = try await MLComputePlan.load(contentsOf: modelURL, configuration: cfg)
        if case .program(let program) = plan.modelStructure, let fn = program.functions["main"] {
            for op in fn.block.operations {
                if op.operatorName == "const" { continue }
                totalOps += 1
                switch plan.deviceUsage(for: op)?.preferred {
                case .some(.neuralEngine): shares["ane"]! += 1
                case .some(.gpu): shares["gpu"]! += 1
                case .some(.cpu): shares["cpu"]! += 1
                default: shares["unknown"]! += 1
                }
            }
        }
    } catch { FileHandle.standardError.write("plan: \(error)\n".data(using: .utf8)!) }
    sem.signal()
}
sem.wait()

// ---- load + predict ----
let t0 = now()
let model = try! MLModel(contentsOf: modelURL, configuration: cfg)
let tLoad = now() - t0
let inName = model.modelDescription.inputDescriptionsByName.keys.first!
let outName = model.modelDescription.outputDescriptionsByName.keys.first!
let shape = model.modelDescription.inputDescriptionsByName[inName]!.multiArrayConstraint!.shape
let dtype = model.modelDescription.inputDescriptionsByName[inName]!.multiArrayConstraint!.dataType
let n = shape.map { $0.intValue }.reduce(1, *)
precondition(featData.count == n * 4, "feature file has \(featData.count / 4) floats, model wants \(n)")
let arr = try! MLMultiArray(shape: shape, dataType: dtype)
featData.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    let src = p.bindMemory(to: Float.self)
    if dtype == .float32 { let d = arr.dataPointer.bindMemory(to: Float.self, capacity: n); for i in 0..<n { d[i] = src[i] } }
    else { for i in 0..<n { arr[i] = NSNumber(value: src[i]) } }
}
let input = try! MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: arr)])
let t1 = now()
var out = try! model.prediction(from: input)
let tFirst = now() - t1
var times: [Double] = []
var peak = footprint().peak
for _ in 0..<iters {
    let s = now(); out = try! model.prediction(from: input); times.append(now() - s)
}
let fp = footprint(); peak = max(peak, fp.peak)
times.sort()
let med = times.isEmpty ? 0 : times[times.count / 2]
if a.count >= 6, let m = out.featureValue(for: outName)?.multiArrayValue {
    let c = m.count
    var buf = [Float](repeating: 0, count: c)
    for i in 0..<c { buf[i] = m[i].floatValue }
    try! Data(bytes: buf, count: c * 4).write(to: URL(fileURLWithPath: a[5]))
}
let outShape = out.featureValue(for: outName)?.multiArrayValue?.shape.map { $0.intValue } ?? []
let env = ProcessInfo.processInfo.environment
let secondsPerWindow = Double(env["WIN_S"] ?? "20") ?? 20.0, newAudio = Double(env["NEW_S"] ?? "15") ?? 15.0
print("{\"units\":\"\(a[3])\",\"input\":\"\(inName)\",\"output\":\"\(outName)\",\"in_shape\":\(shape.map { $0.intValue }),\"out_shape\":\(outShape),\"ops\":\(totalOps),\"ane\":\(shares["ane"]!),\"gpu\":\(shares["gpu"]!),\"cpu\":\(shares["cpu"]!),\"unknown\":\(shares["unknown"]!),\"load_s\":\(String(format: "%.3f", tLoad)),\"first_s\":\(String(format: "%.3f", tFirst)),\"median_s\":\(String(format: "%.4f", med)),\"rt_x_stride\":\(String(format: "%.2f", newAudio / max(med, 1e-9))),\"rt_x_window\":\(String(format: "%.2f", secondsPerWindow / max(med, 1e-9))),\"peak_gib\":\(String(format: "%.3f", peak)),\"end_gib\":\(String(format: "%.3f", fp.cur))}")
