import Foundation

/// ox-diar's command line, parsed where `swift test` can see it: anything that is not exactly a known shape is a
/// usage error, never a partial parse that dies inside FluidAudio.
public enum Arguments {
    /// The diarization pipeline a diarize run uses. The positional form (no flag) is the pyannote engine — the
    /// daemon names no flag yet — until Task 8 flips the default.
    public enum Engine: String, Sendable {
        case pyannote, nemotron
    }

    public enum Command: Equatable {
        case version
        case diarize(pcm: String, out: String, models: String, engine: Engine)
        case usage(String)
    }

    private static let usageLine =
        "usage: ox-diar <pcm16k-mono-s16le> <out.json> --models DIR [--engine pyannote|nemotron]"

    /// Parses argv (without the executable). `env` is the process environment: there is deliberately no env
    /// layer for the engine — the flag alone picks it — but the tests pin that rule by passing a map here.
    public static func parse(_ argv: [String], env: [String: String]) -> Command {
        if argv == ["--version"] { return .version }
        guard argv.count == 4 || argv.count == 6, argv[2] == "--models" else {
            return .usage(usageLine)
        }
        var engine = Engine.pyannote
        if argv.count == 6 {
            guard argv[4] == "--engine", let parsed = Engine(rawValue: argv[5]) else {
                return .usage(usageLine)
            }
            engine = parsed
        }
        return .diarize(pcm: argv[0], out: argv[1], models: argv[3], engine: engine)
    }
}
