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

    /// The soft landing for the Neural Engine: a throw anywhere in an attempt — the load or the whole stream —
    /// retries the whole attempt once on the CPU, on fresh models. A macOS update can break the ANE compile
    /// (one was measured on 26.7) or the first prediction (the "Unable to compute the prediction" class the
    /// Intel leg recorded, ci.yml), and slow voices beat an exit with no answer; only a second failure reaches
    /// the caller, tagged by the phase that threw it so main.swift keeps the exit-code contract. A forced-CPU
    /// run (`OX_DIAR_COMPUTE_UNITS=cpuOnly`) has nowhere lower to fall and does not retry. `fellBack` marks a
    /// retried run: `timing_s` records it, the only record that outlives stderr.
    /// `load` and `stream` are the test seam: a test records the unit sequence each attempt saw and which
    /// models each stream ran on, so a dropped retry — or a stream left outside it — is caught.
    public static func withNemotronUnits<Models, R>(
        env: [String: String],
        load: (MLComputeUnits) async throws -> Models,
        stream: (Models) throws -> R
    ) async throws -> (value: R, fellBack: Bool) {
        let units = effectiveUnits(env: env)
        do {
            return (try await attempt(units, load: load, stream: stream), false)
        } catch {
            guard units != .cpuOnly else { throw error }
            FileHandle.standardError.write(
                Data("ox-diar: Neural Engine run failed, retrying on CPU: \(error.localizedDescription)\n".utf8))
            return (try await attempt(.cpuOnly, load: load, stream: stream), true)
        }
    }

    /// One attempt at `units`: the load, then the whole stream over what it loaded. The error is tagged by the
    /// phase that threw it; a retry runs the whole attempt again on fresh models, not only the phase that failed.
    private static func attempt<Models, R>(
        _ units: MLComputeUnits,
        load: (MLComputeUnits) async throws -> Models,
        stream: (Models) throws -> R
    ) async throws -> R {
        let models: Models
        do {
            models = try await load(units)
        } catch {
            throw NemotronPhaseError.load(error)
        }
        do {
            return try stream(models)
        } catch {
            throw NemotronPhaseError.stream(error)
        }
    }

    /// ox-diar's Nemotron loader: FluidAudio's models from `directory` (which holds the fast128 bundle and the
    /// `.bin` assets fetch-models.sh laid out) at `units`. The compute-units line test_cli.py reads is logged
    /// after the load, from the loaded model's own configuration — a loader handed other units cannot write a
    /// clean line over a bad run.
    public static func loadNemotron(from directory: URL, computeUnits units: MLComputeUnits) async throws -> Nemotron3Models {
        // This overload, never loadFromHuggingFace: its discardStaleCache deletes a directory that lacks
        // FluidAudio's own marker; ours is .ox-say-revision.
        let models = try await Nemotron3Models.load(config: nemotron, directory: directory, computeUnits: units)
        FileHandle.standardError.write(Data("ox-diar: compute units \(name(of: models.model.configuration.computeUnits))\n".utf8))
        return models
    }

    /// The name of a compute-units value, for the line `loadNemotron` logs (test_cli.py reads it back from the
    /// binary).
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

/// Which part of a Nemotron attempt failed: the load (a models problem, exit 3) or the stream (a run that
/// broke after it, exit 1). `withNemotronUnits` rethrows the attempt's error wrapped in this, and the daemon's
/// retry-or-unavailable mapping depends on the distinction.
public enum NemotronPhaseError: Error {
    case load(Error)
    case stream(Error)

    /// The failure that reached us, without the phase tag.
    public var underlying: Error {
        switch self { case .load(let e), .stream(let e): e }
    }

    /// The exit code ox-diar answers with: internal/daemon/diarize.go's contract (`diarExitModels`,
    /// `engine_error` otherwise).
    public var exitCode: ExitCode {
        switch self { case .load: .models; case .stream: .failure }
    }
}

extension NemotronPhaseError: LocalizedError {
    public var errorDescription: String? { underlying.localizedDescription }
}
