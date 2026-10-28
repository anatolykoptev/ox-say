import CoreML
import FluidAudio
import Foundation

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

    /// Neural Engine and CPU, so the GPU stays free for Parakeet (measured 0 % against 98 % on `.all`). ox-diar has
    /// no Intel build: the models failed on `.cpuOnly` on the Intel CI runner (plan Task 20a), and the x86_64 package
    /// carries none, so there is no per-architecture choice to make.
    public static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// The Core ML configuration the models are loaded with.
    public static func mlConfiguration() -> MLModelConfiguration {
        let ml = MLModelConfiguration()
        ml.computeUnits = computeUnits
        return ml
    }

    /// Loads the models through `load`, handing it the pinned configuration, and logs the compute units of the
    /// configuration it passed (test_cli.py reads that line back from the binary). `load` is a seam for
    /// `swift test` only: the tests record what it receives, so a loader called with another configuration, or none,
    /// is caught, which a log line or a free-standing `mlConfiguration()` check could not see.
    public static func loadModels<Models>(
        from directory: URL,
        using load: (URL, MLModelConfiguration) async throws -> Models
    ) async throws -> Models {
        let ml = mlConfiguration()
        FileHandle.standardError.write(Data("ox-diar: compute units \(name(of: ml.computeUnits))\n".utf8))
        return try await load(directory, ml)
    }

    /// ox-diar's loader: FluidAudio's offline diarizer models from `directory`.
    public static func loadModels(from directory: URL) async throws -> OfflineDiarizerModels {
        try await loadModels(from: directory, using: { url, ml in
            try await OfflineDiarizerModels.load(from: url, configuration: ml)
        })
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
}
