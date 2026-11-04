import Foundation

/// A refusal ox-clean can explain. Every error that can reach the command line is one of these, so Task 8 maps
/// them to an exit code without guessing, and nothing on a user-reachable path ends in a trap.
///
/// Not covered: `WavIO.StreamWriter.append`/`finish` errors (POSIXError, `WavIO.Failure`) and the Foundation error of an
/// unreadable input pass through `Cleaner.run` unmapped; Task 8 maps them (an unreadable input to `ExitCode.input`, a
/// failed write to `ExitCode.failure`) and calls `abandon()` first.
public enum Failure: Error, Equatable, CustomStringConvertible {
    /// The models are missing, disagree with this engine, or give a wrong answer. `reason` is a short code
    /// ("shape", "known_answer", ...), `detail` one plain sentence for the user.
    case models(String, detail: String = "")
    /// The audio cannot be cleaned: empty, or it holds NaN/Inf.
    case input(String, detail: String = "")
    /// The run itself failed: a model error, a wrong-sized output, a platform call that returned nothing.
    case processing(String, detail: String = "")

    public var reason: String {
        switch self {
        case .models(let r, _), .input(let r, _), .processing(let r, _): return r
        }
    }

    public var detail: String {
        switch self {
        case .models(_, let d), .input(_, let d), .processing(_, let d): return d
        }
    }

    public var exitCode: ExitCode {
        switch self {
        case .models: return .models
        case .input: return .input
        case .processing: return .failure
        }
    }

    public var description: String { detail.isEmpty ? reason : detail }
}
