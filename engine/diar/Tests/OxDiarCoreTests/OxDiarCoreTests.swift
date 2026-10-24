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

    @Test func theGPUIsLeftToParakeetOnAppleSilicon() {
        #expect(Pinned.computeUnits(arm64: true) == .cpuAndNeuralEngine)
        #expect(Pinned.computeUnits(arm64: false) == .cpuOnly)
    }

    /// main.swift builds the Core ML configuration through `Pinned.mlConfiguration`, so this is the call it makes.
    @Test func theCoreMLConfigurationCarriesThePinnedComputeUnits() {
        #expect(Pinned.mlConfiguration(arm64: true).computeUnits == .cpuAndNeuralEngine)
        #expect(Pinned.mlConfiguration(arm64: false).computeUnits == .cpuOnly)
        #expect(Pinned.mlConfiguration().computeUnits == Pinned.computeUnits(arm64: Pinned.runsOnArm64))
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
