import Foundation

/// A long voiceover project as the daemon reports it (`POST /v1/produce`,
/// `GET /v1/produce` and `GET /v1/produce/{id}` all answer with this summary).

/// The daemon's job states (vproject.Status*). An unknown word decodes to
/// `.unknown` and counts as active, so a state added later never ends the
/// polling of a job that is still working.
public enum ProduceStatus: Equatable {
    case running
    case waitingForDictation
    case pausedOnBattery
    /// Done, and some parts need a listen.
    case review
    case done
    case failed
    case cancelled
    /// The daemon stopped mid-run; the job needs a resume to continue.
    case interrupted
    case unknown(String)

    public init(_ word: String) {
        switch word {
        case "running": self = .running
        case "waiting_for_dictation": self = .waitingForDictation
        case "paused_on_battery": self = .pausedOnBattery
        case "review": self = .review
        case "done": self = .done
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        default: self = .unknown(word)
        }
    }

    /// The job has ended for good (or until the person resumes it): nothing
    /// changes by asking again.
    public var isTerminal: Bool {
        switch self {
        case .review, .done, .failed, .cancelled, .interrupted: return true
        case .running, .waitingForDictation, .pausedOnBattery, .unknown: return false
        }
    }
}

/// How the person picks the kind of voiceover; each maps to a daemon preset.
public enum ProduceFormat: Equatable, CaseIterable {
    case short
    case long

    public var title: String {
        switch self {
        case .short: return "Reels / Shorts (short)"
        case .long: return "YouTube (long)"
        }
    }

    /// The daemon's preset names (produce.go `presets`).
    public var preset: String {
        switch self {
        case .short: return "reels"
        case .long: return "youtube"
        }
    }
}

public struct ProduceJob: Equatable {
    public var id: String
    public var title: String
    public var status: ProduceStatus
    public var partsTotal: Int
    public var partsDone: Int
    /// How many parts the automatic checks left for the person to listen to.
    public var partsToReview: Int
    /// The daemon's own failure message, when it failed.
    public var error: String?
    /// The published WAV's absolute path; nil until the job has finished.
    public var outputPath: String?

    public init(id: String, title: String, status: ProduceStatus, partsTotal: Int = 0, partsDone: Int = 0,
                partsToReview: Int = 0, error: String? = nil, outputPath: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.partsTotal = partsTotal
        self.partsDone = partsDone
        self.partsToReview = partsToReview
        self.error = error
        self.outputPath = outputPath
    }

    /// The folder the finished files are in.
    public var outputFolder: URL? {
        outputPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    /// One summary object; nil without an id.
    static func decode(_ obj: [String: Any]) -> ProduceJob? {
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let progress = obj["progress"] as? [String: Any]
        let outputs = obj["outputs"] as? [String: Any]
        let chunks = obj["chunks"] as? [[String: Any]] ?? []
        let wav = outputs?["wav"] as? String
        return ProduceJob(
            id: id,
            title: obj["title"] as? String ?? "",
            status: ProduceStatus(obj["status"] as? String ?? ""),
            partsTotal: progress?["chunks_total"] as? Int ?? 0,
            partsDone: progress?["chunks_done"] as? Int ?? 0,
            partsToReview: chunks.filter { $0["status"] as? String == "review" }.count,
            error: (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            outputPath: wav.flatMap { $0.isEmpty ? nil : $0 })
    }

    public static func decode(_ data: Data) -> ProduceJob? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(decode)
    }

    /// `GET /v1/produce`: `{"projects": [...]}` newest first, or null when none exist.
    public static func decodeList(_ data: Data) -> [ProduceJob]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = obj["projects"] as? [[String: Any]] ?? []
        return list.compactMap(decode)
    }
}

/// `POST /v1/produce` and the job controls.
public enum ProduceRequest {
    /// The body of a new voiceover. An empty title or voice is left out so the
    /// daemon picks its own (the script's first words, the configured voice).
    public static func createBody(script: String, title: String, voice: String?, format: ProduceFormat) -> Data {
        var body: [String: Any] = ["script": script, "preset": format.preset]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["title"] = trimmed }
        if let voice, !voice.isEmpty { body["voice"] = voice }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The daemon's cap on a script (produce.go maxProduceChars), about 48 minutes of speech.
    public static let scriptLimit = 40000

    /// Why a file cannot be voiced, in plain words; nil when it can.
    public static func scriptProblem(_ script: String) -> String? {
        let length = script.trimmingCharacters(in: .whitespacesAndNewlines).count
        if length == 0 { return "The file has no text in it." }
        if length > scriptLimit {
            return "The file is too long: a voiceover can be up to \(scriptLimit) characters (about 48 minutes), and this one has \(length)."
        }
        return nil
    }

    /// Resume with the battery allowed: the whole of "Continue on Battery Power".
    public static func resumeOnBatteryBody() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["allow_battery": true])) ?? Data()
    }
}

public enum ProduceText {
    /// How often the app asks about a job it started, seconds.
    public static let pollInterval: TimeInterval = 5

    /// Whether to ask again after this answer: only while the job is not over.
    public static func shouldKeepPolling(_ job: ProduceJob) -> Bool {
        !job.status.isTerminal
    }

    /// The menu's progress row: `“Title” — 3 of 10 parts`, or why it is not moving.
    public static func progressRow(_ job: ProduceJob) -> String {
        let name = job.title.isEmpty ? "Voiceover" : "“\(job.title)”"
        return "\(name) — \(progressDetail(job))"
    }

    private static func progressDetail(_ job: ProduceJob) -> String {
        switch job.status {
        case .pausedOnBattery: return "paused — on battery power"
        case .waitingForDictation: return "paused — you are dictating"
        case .review: return "ready — \(listenText(job.partsToReview))"
        case .done: return "ready"
        case .failed: return "failed"
        case .cancelled: return "stopped"
        case .interrupted: return "interrupted"
        case .running, .unknown:
            return job.partsTotal > 0 ? "\(job.partsDone) of \(job.partsTotal) parts" : "starting…"
        }
    }

    private static func listenText(_ count: Int) -> String {
        count == 1 ? "1 part needs a listen" : "\(count) parts need a listen"
    }

    /// The alert for a job that ended; nil for one that was stopped on purpose.
    public static func finishAlert(_ job: ProduceJob) -> (title: String, text: String)? {
        switch job.status {
        case .done, .review:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the voiceover"
            var text = "Saved as \(file)."
            if job.status == .review {
                text += " \(listenText(job.partsToReview)). They are in the folder."
            }
            return ("Voiceover ready", text)
        case .failed:
            return ("The voiceover failed", job.error ?? "ox-say could not finish it.")
        case .interrupted:
            return ("The voiceover was interrupted",
                    "ox-say stopped while it was working. Start it again with New Voiceover from Text File.")
        case .cancelled, .running, .waitingForDictation, .pausedOnBattery, .unknown:
            return nil
        }
    }
}
