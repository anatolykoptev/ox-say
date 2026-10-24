import CoreML
import FluidAudio

/// The configuration and the compute units ox-diar runs with, as functions the unit tests can read: a different value
/// is a different accuracy claim (or a GPU taken from Parakeet), and a test that only runs the binary cannot see it.
public enum Pinned {
    /// The spike's `parity0`: the community-1 recipe's AHC threshold and window step, no 1 s floor on a segment,
    /// the exclusive timeline.
    public static func config() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.clustering.threshold = 0.7
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0
        config.postProcessing.exclusiveSegments = true
        return config
    }

    /// Apple Silicon: Neural Engine and CPU, the GPU stays free for Parakeet (measured 0 % against 98 % on `.all`).
    /// Intel has no Neural Engine.
    public static func computeUnits(arm64: Bool) -> MLComputeUnits {
        arm64 ? .cpuAndNeuralEngine : .cpuOnly
    }

    /// The Core ML configuration the models are loaded with. main.swift calls this, so `swift test` exercises the
    /// call it makes rather than a function it could bypass.
    public static func mlConfiguration(arm64: Bool = runsOnArm64) -> MLModelConfiguration {
        let ml = MLModelConfiguration()
        ml.computeUnits = computeUnits(arm64: arm64)
        return ml
    }

    /// The name of a compute-units value, for the line main.swift logs (test_cli.py reads it back from the binary).
    public static func name(of units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "unknown"
        }
    }

    public static var runsOnArm64: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
