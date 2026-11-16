import Foundation
import Testing
@testable import OxDiarCore

/// The command line of ox-diar, parsed where `swift test` can see it: anything not exactly a known shape is a
/// usage error, never a partial parse that dies inside FluidAudio.
@Suite struct ArgumentsTests {
    @Test func thePositionalFormDiarizes() {
        #expect(Arguments.parse(["in.pcm", "out.json", "--models", "d"])
            == .diarize(pcm: "in.pcm", out: "out.json", models: "d"))
    }

    /// An older daemon names the engine on every run, so the flag stays accepted for the only engine left.
    @Test func theNemotronEngineFlagIsStillAccepted() {
        #expect(Arguments.parse(["in.pcm", "out.json", "--models", "d", "--engine", "nemotron"])
            == .diarize(pcm: "in.pcm", out: "out.json", models: "d"))
    }

    /// The removed pyannote engine is a usage error, not a quiet fall-back: the daemon never asks for it, and a
    /// caller that does has a stale idea of this binary.
    /// Mutation: Arguments.swift, `argv[5] == "nemotron"` -> `argv[5] == "nemotron" || argv[5] == "pyannote"` turns
    /// this red.
    @Test func anUnknownOrDanglingEngineIsUsage() {
        for argv in [
            ["a.pcm", "b.json", "--models", "d", "--engine", "pyannote"],
            ["a.pcm", "b.json", "--models", "d", "--engine", "bogus"],
            ["a.pcm", "b.json", "--models", "d", "--engine"],
            ["a.pcm", "b.json", "--models", "d", "--warm", "nemotron"],
        ] {
            guard case .usage = Arguments.parse(argv) else {
                Issue.record("\(argv) is not a usage error")
                continue
            }
        }
    }

    @Test func versionAndEveryOtherShapeIsExact() {
        #expect(Arguments.parse(["--version"]) == .version)
        for argv in [
            [String](),
            ["a.pcm", "b.json"],
            ["a.pcm", "b.json", "--models"],
            ["a.pcm", "b.json", "--bogus", "d"],
            ["a.pcm", "b.json", "--models", "d", "extra"],
            ["a.pcm", "b.json", "--engine", "nemotron", "--models", "d"],
            ["--version", "extra"],
        ] {
            guard case .usage = Arguments.parse(argv) else {
                Issue.record("\(argv) is not a usage error")
                continue
            }
        }
    }
}
