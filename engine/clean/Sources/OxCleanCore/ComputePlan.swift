import CoreML
import Foundation
import Metal

/// What `MTLDevice` says about one GPU; the only two facts the choice needs.
public struct GPUDescription: Equatable, Sendable {
    public var isLowPower: Bool
    public var isRemovable: Bool
    public init(isLowPower: Bool, isRemovable: Bool) {
        self.isLowPower = isLowPower
        self.isRemovable = isRemovable
    }
}

public enum CPUArchitecture: Equatable, Sendable {
    case arm64, x86_64

    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// Where the model runs. `discreteGPUIndex` is the position, in `MTLCopyAllDevices()`, of the GPU to set as
/// `MLModelConfiguration.preferredMetalDevice`; nil means "leave it to Core ML".
public struct ComputePlan: Equatable {
    public var units: MLComputeUnits
    public var discreteGPUIndex: Int?
}

/// Controller decisions 5 and 8, as a pure function of the machine so a table can test it:
/// - arm64: `.cpuAndGPU`. (`.cpuOnly` renders the first ~64 frames of each window as garbage on macOS 26.5.1.)
/// - x86_64 with a discrete Metal GPU (the first device that is neither low-power nor removable): `.cpuAndGPU`
///   on that device.
/// - x86_64 with only an integrated GPU (or none): `.cpuOnly`. The iGPU is 13x slower and runs out of memory.
/// Never `.all` and never the Neural Engine. `OX_CLEAN_COMPUTE_UNITS=cpuOnly` may lower the choice; no value raises it.
public enum ComputeChoice {
    public static func plan(architecture: CPUArchitecture, gpus: [GPUDescription], override: String?) -> ComputePlan {
        var plan: ComputePlan
        switch architecture {
        case .arm64:
            plan = ComputePlan(units: .cpuAndGPU, discreteGPUIndex: nil)
        case .x86_64:
            if let i = gpus.firstIndex(where: { !$0.isLowPower && !$0.isRemovable }) {
                plan = ComputePlan(units: .cpuAndGPU, discreteGPUIndex: i)
            } else {
                plan = ComputePlan(units: .cpuOnly, discreteGPUIndex: nil)
            }
        }
        if override == "cpuOnly" { plan = ComputePlan(units: .cpuOnly, discreteGPUIndex: nil) }
        return plan
    }

    /// The plan for this machine, with the environment's override.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ComputePlan {
        let gpus: [GPUDescription]
        switch CPUArchitecture.current {
        case .arm64: gpus = []
        case .x86_64: gpus = MTLCopyAllDevices().map { GPUDescription(isLowPower: $0.isLowPower, isRemovable: $0.isRemovable) }
        }
        return plan(architecture: .current, gpus: gpus, override: environment["OX_CLEAN_COMPUTE_UNITS"])
    }
}
