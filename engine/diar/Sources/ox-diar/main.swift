import CoreML
import FluidAudio
import Foundation
import OxDiarCore

// ox-diar <pcm16k-mono-s16le> <out.json> --models DIR      one diarization, then exit
// ox-diar --version
// DIR holds speaker-diarization/ with the 24 files scripts/fetch-models.sh downloads. Nothing here touches the
// network: ModelHub.offlineMode makes every download path throw, so a missing model is exit 3, never a fetch.
// Exit codes: OxDiarCore.ExitCode.

func die(_ code: ExitCode, _ message: String) -> Never {
    FileHandle.standardError.write(Data("ox-diar: \(message)\n".utf8))
    exit(code.rawValue)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print(Pins.versionLine)
    exit(ExitCode.ok.rawValue)
}
guard arguments.count == 4, arguments[2] == "--models" else {
    die(.usage, "usage: ox-diar <pcm16k-mono-s16le> <out.json> --models DIR")
}
let pcmPath = arguments[0]
let outPath = arguments[1]
let modelsDir = URL(fileURLWithPath: arguments[3], isDirectory: true)

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

// Every download path throws; the models are the files scripts/fetch-models.sh laid out, whose
// .fluidaudio-revision marker names the revision FluidAudio 0.17.7 itself asks for (Pins.modelsRevision).
ModelHub.offlineMode = true

// The configuration and the compute units are pinned in OxDiarCore (Pinned), where `swift test` reads them.
let ml = Pinned.mlConfiguration()
FileHandle.standardError.write(Data("ox-diar: compute units \(Pinned.name(of: ml.computeUnits))\n".utf8))

let started = Date()
let models: OfflineDiarizerModels
do {
    models = try await OfflineDiarizerModels.load(from: modelsDir, configuration: ml)
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

let answer = Diarization.make(
    duration: duration, segments: segments,
    timing: ["load": loaded.timeIntervalSince(started), "diarize": finished.timeIntervalSince(loaded)])
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
