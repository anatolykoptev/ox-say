import CoreML
import FluidAudio
import Foundation
import Testing
@testable import OxDiarCore

private func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
    OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
}

@Suite struct PlatformTests {
    @Test func macOS14IsRefusedAndMacOS15IsNot() {
        #expect(Platform.refusal(version: os(14, 8)) != nil)
        #expect(Platform.refusal(version: os(13, 6)) != nil)
        #expect(Platform.refusal(version: os(15, 0)) == nil)
        #expect(Platform.refusal(version: os(26, 5)) == nil)
    }

    @Test func theAssumedVersionOnlyLowersTheRealOne() {
        let real = os(15, 7)
        #expect(Platform.effectiveVersion(real: real, assume: "14.8").majorVersion == 14)
        #expect(Platform.effectiveVersion(real: real, assume: "99").majorVersion == 15, "cannot raise")
        #expect(Platform.effectiveVersion(real: real, assume: "nonsense").majorVersion == 15)
        #expect(Platform.effectiveVersion(real: real, assume: nil).majorVersion == 15)
        #expect(Platform.refusal(version: Platform.effectiveVersion(real: os(14, 2), assume: "26")) != nil, "a 14 stays 14")
    }
}

@Suite struct OutputTests {
    private func raw(_ s: Double, _ e: Double, _ who: String, _ emb: [Float] = [1]) -> RawSegment {
        RawSegment(start: s, end: e, speaker: who, embedding: emb)
    }

    @Test func speakersAreDenseAndOrderedBySpeech() {
        let d = Diarization.make(duration: 30, segments: [
            raw(0, 2, "S9", [9]), raw(2, 12, "S2", [2]), raw(12, 14, "S9", [9]), raw(14, 15, "S5", [5]),
        ], timing: [:])
        #expect(d.speakers.map(\.id) == [0, 1, 2])
        #expect(d.speakers.map(\.speechS) == [10, 4, 1])
        #expect(d.speakers.map(\.embedding) == [[2], [9], [5]])
        #expect(d.segments.map(\.spk) == [1, 0, 1, 2])
    }

    @Test func emptyAndInvertedSegmentsAreDroppedAndTheRestIsSorted() {
        let d = Diarization.make(duration: 5, segments: [
            raw(3, 4, "a"), raw(1, 1.0004, "a"), raw(2, 1, "a"), raw(0.5, 2, "b"),
        ], timing: [:])
        #expect(d.segments.map(\.s) == [0.5, 3])
        #expect(d.speakers.count == 2)
    }

    @Test func noSegmentsIsAnEmptyAnswerWithTheDuration() throws {
        let d = Diarization.make(duration: 12.34567, segments: [], timing: ["load": 1])
        let json = try #require(String(data: d.encoded(), encoding: .utf8))
        #expect(json == #"{"duration_s":12.346,"segments":[],"speakers":[],"timing_s":{"load":1},"version":1}"#)
    }

    @Test func theJSONCarriesTheKeysTheGoSideReads() throws {
        let d = Diarization.make(duration: 3, segments: [raw(0, 2, "a", [0.5, 0.25])], timing: [:])
        let obj = try #require(try JSONSerialization.jsonObject(with: d.encoded()) as? [String: Any])
        #expect(obj["version"] as? Int == 1)
        let speaker = try #require((obj["speakers"] as? [[String: Any]])?.first)
        #expect(Set(speaker.keys) == ["id", "speech_s", "embedding"])
        let segment = try #require((obj["segments"] as? [[String: Any]])?.first)
        #expect(Set(segment.keys) == ["s", "e", "spk"])
    }
}

@Suite struct PinsTests {
    /// Package.resolved is the registry: the version Pins names must be the one SwiftPM resolved.
    @Test func thePinMatchesPackageResolved() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Package.resolved")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pins = try #require(obj["pins"] as? [[String: Any]])
        let fluid = try #require(pins.first { ($0["identity"] as? String) == "fluidaudio" })
        let state = try #require(fluid["state"] as? [String: Any])
        #expect(state["version"] as? String == Pins.fluidAudioVersion)
    }

    /// The Nemotron set's revision is the one fetch-models.sh pins (`nem_rev`); the Go pin test
    /// (TestDiarPinsAgreeAcrossLanguages) holds the same constant against internal/config.NemotronModelsRevision.
    @Test func theNemotronPinMatchesFetchModels() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fetch-models.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.hasPrefix("nem_rev=") }
        #expect(line == "nem_rev=\(Pins.nemotronModelsRevision)")
    }
}

@Suite struct PinnedTests {
    /// The spike's `parity0`, read back from the configuration ox-diar runs with.
    @Test func theConfigurationIsTheMeasuredOne() {
        let c = Pinned.config()
        #expect(c.clustering.threshold == 0.7)
        #expect(c.segmentation.stepRatio == 0.1)
        #expect(c.embedding.minSegmentDurationSeconds == 0)
        #expect(c.postProcessing.exclusiveSegments)
    }

    @Test func theGPUIsLeftToParakeet() {
        #expect(Pinned.computeUnits == .cpuAndNeuralEngine)
        #expect(Pinned.mlConfiguration().computeUnits == .cpuAndNeuralEngine)
    }

    /// main.swift loads the models through `Pinned.loadModels(from:)`, which hands the loader its configuration.
    /// A recording loader stands in for `OfflineDiarizerModels.load`, so this sees what is PASSED to it, not what is
    /// logged: a loader called with a default configuration (or none) turns this red.
    @Test func theLoaderIsHandedThePinnedComputeUnits() async throws {
        var seen: [(URL, MLComputeUnits)] = []
        let dir = URL(fileURLWithPath: "/models", isDirectory: true)
        let marker = try await Pinned.loadModels(from: dir, using: { url, ml in
            seen.append((url, ml.computeUnits))
            return 42
        })
        #expect(marker == 42, "the loader's result is returned")
        #expect(seen.count == 1)
        #expect(seen.first?.0 == dir)
        #expect(seen.first?.1 == .cpuAndNeuralEngine)
    }

    @Test func aLoaderFailureIsNotSwallowed() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await Pinned.loadModels(from: URL(fileURLWithPath: "/m"), using: { (_: URL, _: MLModelConfiguration) async throws -> Int in throw Boom() })
        }
    }

    /// The name main.swift logs and test_cli.py reads back from the real binary's stderr.
    @Test func computeUnitsHaveStableNames() {
        #expect(Pinned.name(of: .cpuAndNeuralEngine) == "cpuAndNeuralEngine")
        #expect(Pinned.name(of: .cpuOnly) == "cpuOnly")
        #expect(Pinned.name(of: .all) == "all")
        #expect(Pinned.name(of: .cpuAndGPU) == "cpuAndGPU")
    }

    /// The loader accepts the models' revision marker only when it equals the revision the library asks for.
    @Test func theModelsRevisionIsTheOneTheLibraryAsksFor() {
        #expect(Pins.modelsRevision == Repo.diarizer.revision)
    }

    /// The Nemotron preset ox-diar runs: fast128, the largest monolithic chunk that still compiles for the
    /// Neural Engine (192 fails ANECCompile) and the one the spike measured. Never a split preset: `splitGraph`
    /// can put part of the graph on the GPU.
    @Test func theNemotronPresetIsFast128() {
        #expect(Pinned.nemotron.modelFileName == "Nemotron3Diarizer_fast128.mlmodelc")
        #expect(Pinned.nemotron.chunkLen == 128)
    }

    /// OX_DIAR_COMPUTE_UNITS can only lower the units a Nemotron run asks for (CI runners have no Neural
    /// Engine); anything but `cpuOnly` is ignored, like OX_DIAR_ASSUME_MACOS.
    @Test func theUnitsEnvCanOnlyLowerThem() {
        #expect(Pinned.effectiveUnits(env: [:]) == .cpuAndNeuralEngine)
        #expect(Pinned.effectiveUnits(env: ["OX_DIAR_COMPUTE_UNITS": "cpuOnly"]) == .cpuOnly)
        #expect(Pinned.effectiveUnits(env: ["OX_DIAR_COMPUTE_UNITS": "all"]) == .cpuAndNeuralEngine)
        #expect(Pinned.effectiveUnits(env: ["OX_DIAR_COMPUTE_UNITS": "gpu"]) == .cpuAndNeuralEngine)
        #expect(Pinned.effectiveUnits(env: ["OX_DIAR_COMPUTE_UNITS": "CPUONLY"]) == .cpuAndNeuralEngine)
    }

    /// The soft landing covers the whole run: a load that fails under the Neural Engine retries once on the
    /// CPU (an ANE-compile failure was seen on a macOS update), and the retry is a fresh attempt — new models,
    /// new units. The recording loader sees the units each attempt asked for, so a dropped retry — or a retry
    /// that also asks for the ANE — is caught.
    @Test func aFailedANELoadRetriesOnceOnTheCPUOnFreshModels() async throws {
        var seen: [MLComputeUnits] = []
        var streamed: [Int] = []
        var loads = 0
        struct Boom: Error {}
        let outcome = try await Pinned.withNemotronUnits(
            env: [:],
            load: { units in
                seen.append(units)
                loads += 1
                if loads == 1 { throw Boom() }
                return loads
            },
            stream: { models in streamed.append(models); return models * 10 })
        #expect(outcome.value == 20)
        #expect(outcome.fellBack)
        #expect(seen == [.cpuAndNeuralEngine, .cpuOnly])
        #expect(streamed == [2], "the retry loads fresh models and streams them, not the failed attempt's")
    }

    /// A failure mid-stream retries the same way: the prediction phase is where the documented ANE-class
    /// failure lands (the Intel leg's "Unable to compute the prediction"), so the stream sits inside the
    /// attempt. A run that only retried the load would let this error reach the caller — a stream moved
    /// outside the attempt turns this red.
    @Test func aFailedANEStreamRetriesOnceOnTheCPUOnFreshModels() async throws {
        var seen: [MLComputeUnits] = []
        var streamed: [Int] = []
        var loads = 0
        struct Boom: Error {}
        let outcome = try await Pinned.withNemotronUnits(
            env: [:],
            load: { units in seen.append(units); loads += 1; return loads },
            stream: { models in
                streamed.append(models)
                if models == 1 { throw Boom() }
                return models
            })
        #expect(outcome.value == 2)
        #expect(outcome.fellBack)
        #expect(seen == [.cpuAndNeuralEngine, .cpuOnly])
        #expect(streamed == [1, 2], "each attempt streams the models it just loaded")
    }

    @Test func aWorkingRunAttemptsOnce() async throws {
        var seen: [MLComputeUnits] = []
        let outcome = try await Pinned.withNemotronUnits(
            env: [:],
            load: { units in seen.append(units); return 7 },
            stream: { models in models * 2 })
        #expect(outcome.value == 14)
        #expect(!outcome.fellBack)
        #expect(seen == [.cpuAndNeuralEngine])
    }

    /// A second failure is the one reported, tagged by the phase that threw it (the first error is named in
    /// the retry line); a forced-CPU run has nowhere lower to fall and does not retry.
    @Test func theSecondFailureIsTheOneReportedAndAForcedCPUHasNoRetry() async {
        struct First: Error {}
        struct Second: Error {}
        var loads = 0
        do {
            _ = try await Pinned.withNemotronUnits(
                env: [:],
                load: { (_: MLComputeUnits) async throws -> Int in
                    loads += 1
                    throw loads == 1 ? First() : Second()
                },
                stream: { (_: Int) in 0 })
            Issue.record("a second load failure did not reach the caller")
        } catch let phase as NemotronPhaseError {
            #expect(phase.underlying is Second)
            #expect(phase.exitCode == .models, "the second failure was the load again")
        } catch {
            Issue.record("the phase tag was lost: \(error)")
        }
        #expect(loads == 2)

        var seen: [MLComputeUnits] = []
        do {
            _ = try await Pinned.withNemotronUnits(
                env: ["OX_DIAR_COMPUTE_UNITS": "cpuOnly"],
                load: { units in seen.append(units); throw First() },
                stream: { (_: Int) in 0 })
            Issue.record("a forced-CPU failure did not reach the caller")
        } catch let phase as NemotronPhaseError {
            #expect(phase.underlying is First)
        } catch {
            Issue.record("the phase tag was lost: \(error)")
        }
        #expect(seen == [.cpuOnly], "a forced-CPU run does not retry")
    }

    /// The phase keeps the exit-code contract the daemon reads: a models problem is exit 3, a stream that
    /// broke after the load is exit 1 (a stream failure answered 3 would read as `models_unusable`, which no
    /// retry of the daemon's can fix and which hides a fall-back-able failure).
    @Test func thePhaseKeepsTheExitCodeContract() {
        struct Boom: Error {}
        #expect(NemotronPhaseError.load(Boom()).exitCode == .models)
        #expect(NemotronPhaseError.stream(Boom()).exitCode == .failure)
        #expect(NemotronPhaseError.stream(Boom()).underlying is Boom)
    }
}

@Suite struct PCMTests {
    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ox-diar-pcm-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func samplesAreSignedLittleEndianAndScaled() throws {
        let url = try file([0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0xFF, 0x7F])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try readPCM16(at: url) == [0, 0.5, -1, Float(32767) / 32768])
    }

    @Test func anOddTrailingByteIsIgnoredAndAnEmptyFileIsAnError() throws {
        let odd = try file([0x00, 0x40, 0x01])
        let empty = try file([])
        let single = try file([0x07])
        defer { for u in [odd, empty, single] { try? FileManager.default.removeItem(at: u) } }
        #expect(try readPCM16(at: odd) == [0.5])
        #expect(throws: PCMError.empty) { try readPCM16(at: empty) }
        #expect(throws: PCMError.empty) { try readPCM16(at: single) }
        #expect(throws: PCMError.unreadable) { try readPCM16(at: URL(fileURLWithPath: "/nonexistent/ox-diar.pcm")) }
    }
}
