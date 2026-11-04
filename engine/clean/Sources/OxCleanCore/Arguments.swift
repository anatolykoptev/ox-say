import Foundation

/// ox-clean's command line, parsed where `swift test` can see it: anything that is not exactly the known shape is a
/// usage error, never a partial parse. `--version` is handled by main before this is called.
public struct Arguments: Equatable {
    public var input: URL
    public var output: URL
    public var modelsDir: URL

    public enum Failure: Error, Equatable { case usage(String) }

    static let usageLine = "usage: ox-clean <in.wav> <out.wav> --models DIR"

    public static func parse(_ argv: [String]) throws -> Arguments {
        guard argv.count == 4, argv[2] == "--models", !argv[0].isEmpty, !argv[1].isEmpty, !argv[3].isEmpty else {
            throw Failure.usage(usageLine)
        }
        return Arguments(input: URL(fileURLWithPath: argv[0]), output: URL(fileURLWithPath: argv[1]),
                         modelsDir: URL(fileURLWithPath: argv[3]))
    }
}
