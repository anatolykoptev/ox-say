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

    /// The compute units a Nemotron run asks for: the pin, or `.cpuOnly` under `OX_DIAR_COMPUTE_UNITS=cpuOnly` —
    /// a seam that can only make the choice MORE conservative (CI runners have no Neural Engine; any other value
    /// is ignored, like `OX_DIAR_ASSUME_MACOS`).
    public static func effectiveUnits(env: [String: String]) -> MLComputeUnits {
        env["OX_DIAR_COMPUTE_UNITS"] == "cpuOnly" ? .cpuOnly : computeUnits
    }

    /// The Nemotron 3 Diarization preset: fast128, the largest monolithic chunk that still compiles for the
    /// Neural Engine (192 fails ANECCompile) and the one the spike measured. Never a split preset: `splitGraph`
    /// can put part of the graph on the GPU.
    public static let nemotron: Nemotron3Config = .fast128

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

    /// Loads the Nemotron models through `load`, handing it the units of `effectiveUnits(env:)` and logging them
    /// like `loadModels` does. The soft landing: a throw under the Neural Engine retries once on the CPU — a
    /// macOS update can break the ANE compile (one was measured on 26.7) and slow voices beat `models_unusable`;
    /// only a second failure reaches the caller. A forced-CPU load has nowhere lower to fall and does not
    /// retry. `load` is the same kind of test seam as `loadModels(from:using:)`: the unit sequence each attempt
    /// saw is what a test records.
    public static func loadNemotron<Models>(
        from directory: URL,
        env: [String: String],
        using load: (URL, MLComputeUnits) async throws -> Models
    ) async throws -> Models {
        let units = effectiveUnits(env: env)
        FileHandle.standardError.write(Data("ox-diar: compute units \(name(of: units))\n".utf8))
        do {
            return try await load(directory, units)
        } catch {
            guard units != .cpuOnly else { throw error }
            FileHandle.standardError.write(Data("ox-diar: ANE load failed, retrying on CPU: \(error.localizedDescription)\n".utf8))
            FileHandle.standardError.write(Data("ox-diar: compute units \(name(of: MLComputeUnits.cpuOnly))\n".utf8))
            return try await load(directory, .cpuOnly)
        }
    }

    /// ox-diar's Nemotron loader: FluidAudio's models from `directory` (which holds the fast128 bundle and the
    /// `.bin` assets fetch-models.sh laid out).
    public static func loadNemotron(from directory: URL, env: [String: String]) async throws -> Nemotron3Models {
        try await loadNemotron(from: directory, env: env, using: { url, units in
            try await Nemotron3Models.load(config: nemotron, directory: url, computeUnits: units)
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
