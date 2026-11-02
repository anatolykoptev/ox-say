import Foundation
import Testing
@testable import OxDiarCore

/// The command line of ox-diar, parsed where `swift test` can see it: anything not exactly a known shape is a
/// usage error, never a partial parse that dies inside FluidAudio.
@Suite struct ArgumentsTests {
    /// The positional form (no flag) is the Nemotron engine. Mutation: Arguments.swift `var engine = Engine.nemotron`
    /// -> `.pyannote` turns this red.
    @Test func thePositionalFormIsTheNemotronEngine() {
        #expect(Arguments.parse(["in.pcm", "out.json", "--models", "d"])
            == .diarize(pcm: "in.pcm", out: "out.json", models: "d", engine: .nemotron))
    }

    @Test func theEngineFlagSelectsTheEngine() {
        #expect(Arguments.parse(["in.pcm", "out.json", "--models", "d", "--engine", "nemotron"])
            == .diarize(pcm: "in.pcm", out: "out.json", models: "d", engine: .nemotron))
        #expect(Arguments.parse(["in.pcm", "out.json", "--models", "d", "--engine", "pyannote"])
            == .diarize(pcm: "in.pcm", out: "out.json", models: "d", engine: .pyannote))
    }

    @Test func anUnknownOrDanglingEngineIsUsage() {
        for argv in [
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
