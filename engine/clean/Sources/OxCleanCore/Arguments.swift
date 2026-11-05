import Foundation

/// ox-clean's command line, parsed where `swift test` can see it: anything that is not exactly the known shape is a
/// usage error, never a partial parse. `--version` is handled by main before this is called.
public struct Arguments: Equatable {
    public var input: URL
    public var output: URL
    public var modelsDir: URL
    /// The output was spelled as a directory ("dir/", "dir/." ...), which `URL` would quietly turn into a file name.
    public var outputIsDirectoryPath = false

    public enum Failure: Error, Equatable { case usage(String) }

    static let usageLine = "usage: ox-clean <in.wav> <out.wav> --models DIR"

    /// `--models DIR` may sit anywhere; `--` ends the options (a file named "-x.wav" needs it); two positionals exactly.
    public static func parse(_ argv: [String]) throws -> Arguments {
        var positional: [String] = []
        var models: String?
        var i = 0
        var optionsEnded = false
        while i < argv.count {
            let arg = argv[i]
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
            } else if arg == "--" {
                optionsEnded = true
            } else if arg == "--models", models == nil, i + 1 < argv.count {
                models = argv[i + 1]
                i += 1
            } else {
                throw Failure.usage(usageLine)
            }
            i += 1
        }
        guard positional.count == 2, let models, !positional[0].isEmpty, !positional[1].isEmpty, !models.isEmpty else {
            throw Failure.usage(usageLine)
        }
        var a = Arguments(input: URL(fileURLWithPath: positional[0]), output: URL(fileURLWithPath: positional[1]),
                          modelsDir: URL(fileURLWithPath: models))
        a.outputIsDirectoryPath = isDirectorySpelling(positional[1])
        return a
    }

    /// "d/", "d//", "d/.", "d/..", ".", "..": names that `URL(fileURLWithPath:)` would turn into a file name or resolve.
    static func isDirectorySpelling(_ path: String) -> Bool {
        if path.hasSuffix("/") { return true }
        let last = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return last == "." || last == ".."
    }
}
