import CoreML
import FluidAudio
import Foundation
import OxDiarCore

// ox-diar <pcm16k-mono-s16le> <out.json> --models DIR [--engine pyannote|nemotron]   one diarization, then exit
// ox-diar --version
// DIR holds the model sets scripts/fetch-models.sh downloads: speaker-diarization/ for the pyannote engine
// (the default until Task 8), nemotron-3-diarization/ for the nemotron engine. Nothing here touches the
// network: ModelHub.offlineMode makes every download path throw, so a missing model is exit 3, never a fetch.
// Exit codes: OxDiarCore.ExitCode.

func die(_ code: ExitCode, _ message: String) -> Never {
    FileHandle.standardError.write(Data("ox-diar: \(message)\n".utf8))
    exit(code.rawValue)
}

let command = Arguments.parse(Array(CommandLine.arguments.dropFirst()))
switch command {
case .version:
    print(Pins.versionLine)
    exit(ExitCode.ok.rawValue)
case .usage(let message):
    die(.usage, message)
case .diarize(let pcmPath, let outPath, let modelsPath, let engine):
    await diarize(pcmPath: pcmPath, outPath: outPath, modelsPath: modelsPath, engine: engine)
}

/// The gates shared by both engines, then the engine's own pipeline, then the JSON answer on disk.
func diarize(pcmPath: String, outPath: String, modelsPath: String, engine: Arguments.Engine) async {
    // Before anything of FluidAudio runs: its BNNS crash on macOS 14 is a crash, not an error.
    let version = Platform.effectiveVersion(
        real: ProcessInfo.processInfo.operatingSystemVersion,
        assume: ProcessInfo.processInfo.environment["OX_DIAR_ASSUME_MACOS"])
    if let why = Platform.refusal(version: version) { die(.unsupportedOS, why) }

    // A missing output directory is a failure now, not after the diarization.
    let outDir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: outDir, isDirectory: &isDirectory), isDirectory.boolValue else {
        die(.failure, "output directory \(outDir) does not exist")
    }

    // Every download path throws; the models are the files scripts/fetch-models.sh laid out.
    ModelHub.offlineMode = true

    let modelsDir = URL(fileURLWithPath: modelsPath, isDirectory: true)
    let duration: Double
    let segments: [RawSegment]
    let timing: [String: Double]
    switch engine {
    case .pyannote:
        (duration, segments, timing) = await diarizePyannote(pcmPath: pcmPath, modelsDir: modelsDir)
    case .nemotron:
        (duration, segments, timing) = await diarizeNemotron(pcmPath: pcmPath, modelsDir: modelsDir)
    }

    let answer = Diarization.make(duration: duration, segments: segments, timing: timing)
    let encoded: Data
    do {
        encoded = try answer.encoded()
    } catch {
        die(.failure, "cannot encode the answer: \(error.localizedDescription)")
    }
    do {
        try encoded.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    } catch {
        die(.failure, "cannot write \(outPath): \(error.localizedDescription)")
    }
}

/// The pyannote engine: segmentation, WeSpeaker embeddings, PLDA, VBx — the pipeline that has been shipping.
/// Its `.fluidaudio-revision` marker (the revision FluidAudio itself asks for, Pins.modelsRevision) is checked
/// by the library's own loader inside `Pinned.loadModels`.
func diarizePyannote(pcmPath: String, modelsDir: URL) async -> (Double, [RawSegment], [String: Double]) {
    // The audio is read here, whole, into memory: no FluidAudio call that writes it to a temporary file (see readPCM16).
    let samples: [Float]
    do {
        samples = try readPCM16(at: URL(fileURLWithPath: pcmPath))
    } catch PCMError.empty {
        die(.input, "\(pcmPath) holds no audio")
    } catch {
        die(.input, "cannot read \(pcmPath)")
    }
    let duration = Double(samples.count) / 16_000

    // The configuration and the compute units are pinned in OxDiarCore (Pinned), where `swift test` reads them.
    let started = Date()
    let models: OfflineDiarizerModels
    do {
        models = try await Pinned.loadModels(from: modelsDir)
    } catch {
        die(.models, "cannot load the models from \(modelsDir.path): \(error.localizedDescription)")
    }
    let loaded = Date()

    let manager = OfflineDiarizerManager(config: Pinned.config())
    manager.initialize(models: models)

    var segments: [RawSegment] = []
    do {
        let result = try await manager.process(audio: samples)
        segments = result.segments.map {
            RawSegment(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId,
                       embedding: $0.embedding)
        }
    } catch OfflineDiarizationError.noSpeechDetected {
        // silence is an answer, not an error
    } catch {
        die(.failure, "diarization failed: \(error.localizedDescription)")
    }
    let finished = Date()
    return (duration, segments,
            ["load": loaded.timeIntervalSince(started), "diarize": finished.timeIntervalSince(loaded)])
}

/// The Nemotron engine: fast128 on the Neural Engine over the mapped file (Variant B — no embeddings, no
/// WeSpeaker load, every speaker's `embedding` stays empty). Its readiness is its own marker: a models dir
/// holding only `nemotron-3-diarization/` runs.
func diarizeNemotron(pcmPath: String, modelsDir: URL) async -> (Double, [RawSegment], [String: Double]) {
    let source: MappedPCM16Source
    do {
        source = try MappedPCM16Source(contentsOf: URL(fileURLWithPath: pcmPath))
    } catch PCMError.empty {
        die(.input, "\(pcmPath) holds no audio")
    } catch {
        die(.input, "cannot read \(pcmPath)")
    }
    let duration = Double(source.sampleCount) / 16_000

    // fetch-models.sh writes the revision it fetched into the marker, our marker — never the pyannote set's
    // .fluidaudio-revision, so a models dir without speaker-diarization/ still runs.
    let nemDir = modelsDir.appendingPathComponent("nemotron-3-diarization", isDirectory: true)
    let marker = try? String(contentsOf: nemDir.appendingPathComponent(Pins.nemotronMarker), encoding: .utf8)
    guard marker?.trimmingCharacters(in: .whitespacesAndNewlines) == Pins.nemotronModelsRevision else {
        die(.models, "the Nemotron models in \(nemDir.path) are missing or from another revision (fetch them with scripts/fetch-models.sh)")
    }

    // The load AND the stream sit inside one retry attempt (Pinned.withNemotronUnits): an ANE failure at the
    // first prediction falls back to the CPU, not to exit 1. The phase tag on the error keeps the exit-code
    // contract — a models problem is exit 3, a stream that broke after it exit 1 — and the timings are the
    // successful attempt's own.
    var loadSeconds = 0.0
    var diarizeSeconds = 0.0
    let outcome: (value: (p: [Float], frames: Int), fellBack: Bool)
    do {
        outcome = try await Pinned.withNemotronUnits(env: ProcessInfo.processInfo.environment) { units in
            let t = Date()
            let models = try await Pinned.loadNemotron(from: nemDir, computeUnits: units)
            loadSeconds = Date().timeIntervalSince(t)
            return models
        } stream: { models in
            let t = Date()
            let r = try NemotronEngine.probabilities(source: source, models: models)
            diarizeSeconds = Date().timeIntervalSince(t)
            return r
        }
    } catch let phase as NemotronPhaseError {
        switch phase {
        case .load(let error):
            die(phase.exitCode, "cannot load the Nemotron models from \(nemDir.path): \(error.localizedDescription)")
        case .stream(let error):
            die(phase.exitCode, "diarization failed: \(error.localizedDescription)")
        }
    } catch {
        die(.failure, "diarization failed: \(error.localizedDescription)")
    }
    let (p, frames) = outcome.value

    var timing = ["load": loadSeconds, "diarize": diarizeSeconds]
    if outcome.fellBack { timing["cpu_fallback"] = 1 }   // ~4x slower; timing_s is the only record that outlives stderr
    let segments = Timeline.raw(Timeline.mergeGaps(Timeline.exclusive(probabilities: p, frameCount: frames)))
    return (duration, segments, timing)
}
