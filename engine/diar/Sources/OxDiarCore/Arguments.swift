import Foundation

/// ox-diar's command line, parsed where `swift test` can see it: anything that is not exactly a known shape is a
/// usage error, never a partial parse that dies inside FluidAudio.
public enum Arguments {
    public enum Command: Equatable {
        case version
        case diarize(pcm: String, out: String, models: String)
        case usage(String)
    }

    private static let usageLine = "usage: ox-diar <pcm16k-mono-s16le> <out.json> --models DIR"

    /// Parses argv (without the executable). `--engine nemotron` is still accepted, and means nothing: the one
    /// engine is the only choice, and a daemon of the release before this one passes the flag. Any other engine
    /// name, the removed `pyannote` included, is a usage error. There is deliberately no env layer for it.
    public static func parse(_ argv: [String]) -> Command {
        if argv == ["--version"] { return .version }
        guard argv.count == 4 || argv.count == 6, argv[2] == "--models" else {
            return .usage(usageLine)
        }
        if argv.count == 6 {
            guard argv[4] == "--engine", argv[5] == "nemotron" else {
                return .usage(usageLine)
            }
        }
        return .diarize(pcm: argv[0], out: argv[1], models: argv[3])
    }
}
