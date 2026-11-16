import Foundation

/// The 200 answer of `POST /v1/audio/clean`: the file that was written and how long the job took.
public struct CleanResult: Equatable {
    public var outPath: String
    public var video: Bool
    public var inputSeconds: Double
    public var elapsedSeconds: Double

    public init(outPath: String, video: Bool, inputSeconds: Double, elapsedSeconds: Double) {
        self.outPath = outPath
        self.video = video
        self.inputSeconds = inputSeconds
        self.elapsedSeconds = elapsedSeconds
    }

    static func decode(_ data: Data) -> CleanResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = obj["out_path"] as? String, !out.isEmpty else { return nil }
        return CleanResult(outPath: out, video: obj["video"] as? Bool ?? false,
                           inputSeconds: obj["input_seconds"] as? Double ?? 0, elapsedSeconds: obj["elapsed_s"] as? Double ?? 0)
    }
}

/// Why the daemon did not clean a file, as the person reads it. The daemon's English sentence is never shown: the stable
/// `error.code` it sends (and, for the codes that several statuses share, the status) picks one of these, and each has its
/// own words in both languages. Nothing was changed on disk in any of them: the output is published only by a complete run.
public enum CleanProblem: Equatable {
    /// Another file is being cleaned (409).
    case busy
    /// Dictation, a meeting or another job holds the machine and did not let go in time (503 `busy`).
    case busySystem
    /// The graphics card stayed taken for the whole wait (503 `gpu_busy`).
    case gpuBusy
    /// The first cleanup started the model download; it has not finished.
    case modelDownloading
    case modelDownloadFailed
    /// The engine or the model is not installed, or cannot be loaded.
    case notInstalled
    case osTooOld
    /// The result could not be written: no space, or the disk refused it.
    case diskFull
    case outputExists
    /// The chosen result would overwrite the original.
    case sameFile
    /// A file that belongs to meetings or dictation: the cleanup never touches those.
    case forbidden
    case notFound
    case noAudio
    case channels
    case tooLong
    /// The result's name or kind does not fit the file (the extension, a picture in an audio name).
    case badOutput
    case timedOut
    case interrupted
    /// Everything the engine or the audio tools can fail with; the details are in the daemon's log.
    case failed

    /// The problem behind an answer that was not 2xx. `code` is `error.code` of the body, nil when the body had none.
    public static func of(status: Int, code: String?) -> CleanProblem {
        switch code {
        case "busy": return status == 409 ? .busy : .busySystem
        case "gpu_busy": return .gpuBusy
        case "models_downloading": return .modelDownloading
        case "models_download_failed": return .modelDownloadFailed
        case "models_missing", "models_unusable", "engine_missing": return .notInstalled
        case "os_too_old": return .osTooOld
        case "disk_space", "engine_output": return .diskFull
        case "exists": return .outputExists
        case "same_file": return .sameFile
        case "forbidden_path": return .forbidden
        case "not_found": return .notFound
        case "no_audio": return .noAudio
        case "unsupported_channels": return .channels
        case "too_long": return .tooLong
        case "invalid_request": return .badOutput
        case "engine_timeout": return .timedOut
        case "engine_interrupted": return .interrupted
        default: return status == 507 ? .diskFull : .failed
        }
    }

    public var key: L10nKey {
        switch self {
        case .busy: return .cleanErrBusy
        case .busySystem: return .cleanErrBusySystem
        case .gpuBusy: return .cleanErrGPUBusy
        case .modelDownloading: return .cleanErrModelDownloading
        case .modelDownloadFailed: return .cleanErrModelDownloadFailed
        case .notInstalled: return .cleanErrNotInstalled
        case .osTooOld: return .cleanReasonOSTooOld
        case .diskFull: return .cleanErrDiskFull
        case .outputExists: return .cleanErrExists
        case .sameFile: return .cleanErrSameFile
        case .forbidden: return .cleanErrForbidden
        case .notFound: return .cleanErrNotFound
        case .noAudio: return .cleanErrNoAudio
        case .channels: return .cleanErrChannels
        case .tooLong: return .cleanErrTooLong
        case .badOutput: return .cleanErrBadOutput
        case .timedOut: return .cleanErrTimedOut
        case .interrupted: return .cleanErrInterrupted
        case .failed: return .cleanErrFailed
        }
    }

    public func sentence(text: (L10nKey) -> String = { $0.text }) -> String { text(key) }
}

/// The daemon refused or failed a cleanup. A cancelled request is not one: it throws `CancellationError`.
public struct CleanError: Error, Equatable {
    public var problem: CleanProblem

    public init(_ problem: CleanProblem) { self.problem = problem }
}

extension StudioClient {
    /// The time limit of one cleanup request: half the recording's length, never under half an hour. The daemon answers when
    /// the file is done (it waits up to two minutes for a quiet machine first, and its first run compiles the model), so the
    /// limit only has to outlast the slowest honest run; a hung daemon is the case it exists for.
    public static func cleanTimeout(forSeconds seconds: Double?) -> TimeInterval {
        max(1800, 0.5 * (seconds ?? 0))
    }

    /// POST /v1/audio/clean: cleans the voice of the file at `input` and writes the result to `output` (a video keeps its
    /// picture and every other stream). The call returns when the file is written. Cancelling the calling task closes the
    /// connection, which makes the daemon stop the job and remove its partial file; that throws `CancellationError`.
    /// `overwrite` is true only when the person has just confirmed replacing an existing file in the save panel.
    public func cleanVoice(input: URL, output: URL, wet: Double = 0.85, overwrite: Bool = false,
                           timeout: TimeInterval) async throws -> CleanResult {
        let body = try Self.jsonBody(["in_path": input.path, "out_path": output.path, "wet": wet, "stereo": "mid",
                                      "overwrite": overwrite])
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(post("v1/audio/clean", body: body, timeout: timeout))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw StudioError.timedOut
        } catch {
            throw StudioError.daemonUnreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw CleanError(CleanProblem.of(status: status, code: (obj?["error"] as? [String: Any])?["code"] as? String))
        }
        guard let result = CleanResult.decode(data) else { throw StudioError.badResponse }
        return result
    }
}
