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

    public func title(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .short: return text(.produceFormatShort)
        case .long: return text(.produceFormatLong)
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

/// A chunk's work status (vproject ChunkStatus*). An unknown word counts as
/// open: a state the daemon adds later must not read as done.
public enum ProduceChunkState: Equatable {
    case pending
    /// Rendered and passed the automatic checks.
    case ok
    /// The checks failed: it is left for the person to listen to.
    case review
    case unknown(String)

    public init(_ word: String) {
        switch word {
        case "pending": self = .pending
        case "ok": self = .ok
        case "review": self = .review
        default: self = .unknown(word)
        }
    }

    /// Still to be rendered, or a word this build does not know.
    public var isOpen: Bool {
        self != .ok && self != .review
    }
}

/// One chunk as the job summary reports it (`chunks[]` of `GET /v1/produce/{id}`).
public struct ProduceChunk: Equatable {
    public var index: Int
    public var status: ProduceChunkState

    public init(index: Int, status: ProduceChunkState) {
        self.index = index
        self.status = status
    }
}

/// One chunk's full view, as `GET /v1/produce/{id}/chunks` and
/// `GET /v1/produce/{id}/chunks/{n}` report it (chunkDetailOut embeds
/// vproject.Chunk's fields at the top level and adds take_files).
public struct ProduceChunkDetail: Equatable, Identifiable {
    public var index: Int
    /// The script paragraph the chunk belongs to — the field only the detail
    /// routes carry, and the phrase→chunk map's key.
    public var paragraph: Int
    /// The chunk's words with directives removed, as the daemon speaks them.
    public var text: String
    public var style: String?
    /// The stored pause in seconds (`pause_after_s`; 0 = no pause).
    public var pauseAfter: Double
    /// The stored pace; 0 is neutral (vproject PaceMin–PaceMax bounds a real one).
    public var pace: Double
    public var status: ProduceChunkState
    /// The take the chunk plays now; nil when none was chosen or checked through.
    public var pick: String?
    /// Every take key the chunk holds, in the manifest's order.
    public var takeKeys: [String]
    /// take key -> the WAV's absolute path (take_files).
    public var takeFiles: [String: String]

    public var id: Int { index }

    public init(index: Int, paragraph: Int, text: String, style: String? = nil, pauseAfter: Double = 0,
                pace: Double = 0, status: ProduceChunkState, pick: String? = nil,
                takeKeys: [String] = [], takeFiles: [String: String] = [:]) {
        self.index = index
        self.paragraph = paragraph
        self.text = text
        self.style = style
        self.pauseAfter = pauseAfter
        self.pace = pace
        self.status = status
        self.pick = pick
        self.takeKeys = takeKeys
        self.takeFiles = takeFiles
    }

    /// nil without both indices — a detail that names neither its chunk nor
    /// its paragraph cannot be mapped. The optional keys follow the daemon's
    /// own omitempty rules: `style`/`pace`/`pick` are absent when unset, and a
    /// takes list may read as null, which is no takes, not a bad answer.
    static func decode(_ obj: [String: Any]) -> ProduceChunkDetail? {
        guard let index = obj["index"] as? Int,
              let paragraph = obj["paragraph"] as? Int else { return nil }
        let takes = obj["takes"] as? [[String: Any]] ?? []
        return ProduceChunkDetail(
            index: index,
            paragraph: paragraph,
            text: obj["text"] as? String ?? "",
            style: obj["style"] as? String,
            pauseAfter: (obj["pause_after_s"] as? NSNumber)?.doubleValue ?? 0,
            pace: (obj["pace"] as? NSNumber)?.doubleValue ?? 0,
            status: ProduceChunkState(obj["status"] as? String ?? ""),
            pick: obj["pick"] as? String,
            takeKeys: takes.compactMap { $0["key"] as? String },
            takeFiles: obj["take_files"] as? [String: String] ?? [:])
    }

    /// `GET /v1/produce/{id}/chunks/{n}`'s bare-object answer.
    public static func decode(_ data: Data) -> ProduceChunkDetail? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(decode)
    }
}

/// One chunk's part of a `POST …/delivery` batch: a nil field leaves the chunk
/// alone, so only a knob the person changed is sent — the daemon's strict
/// decoder answers 400 to a key it does not know.
public struct DeliveryEntry: Equatable {
    public var n: Int
    public var style: String?
    public var pauseAfter: Double?
    public var pace: Double?

    public init(n: Int, style: String? = nil, pauseAfter: Double? = nil, pace: Double? = nil) {
        self.n = n
        self.style = style
        self.pauseAfter = pauseAfter
        self.pace = pace
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
    /// The published audio's length, seconds; nil until the job has finished.
    public var durationS: Double?
    /// Every chunk the summary lists, with its live status.
    public var chunks: [ProduceChunk]

    public init(id: String, title: String, status: ProduceStatus, partsTotal: Int = 0, partsDone: Int = 0,
                partsToReview: Int = 0, error: String? = nil, outputPath: String? = nil,
                durationS: Double? = nil, chunks: [ProduceChunk] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.partsTotal = partsTotal
        self.partsDone = partsDone
        self.partsToReview = partsToReview
        self.error = error
        self.outputPath = outputPath
        self.durationS = durationS
        self.chunks = chunks
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
            outputPath: wav.flatMap { $0.isEmpty ? nil : $0 },
            durationS: (outputs?["duration_s"] as? NSNumber)?.doubleValue,
            chunks: chunks.enumerated().map {
                ProduceChunk(index: $0.element["index"] as? Int ?? $0.offset,
                             status: ProduceChunkState($0.element["status"] as? String ?? ""))
            })
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
    /// daemon picks its own (the script's first words, the configured voice);
    /// so are the optional knobs — a caller that passes none gets the body it
    /// always sent, and the daemon's strict decoder never sees a key it does
    /// not know.
    public static func createBody(script: String, title: String, voice: String?, format: ProduceFormat,
                                  takes: Int? = nil, cloneMode: String? = nil,
                                  loudness: Double? = nil, steps: Int? = nil,
                                  seed: Int? = nil, outPath: String? = nil) -> Data {
        var body: [String: Any] = ["script": script, "preset": format.preset]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["title"] = trimmed }
        if let voice, !voice.isEmpty { body["voice"] = voice }
        if let takes { body["takes"] = takes }
        if let cloneMode, !cloneMode.isEmpty { body["clone_mode"] = cloneMode }
        if let loudness { body["loudness_lufs"] = loudness }
        if let steps { body["inference_timesteps"] = steps }
        if let seed { body["seed"] = seed }
        if let outPath, !outPath.isEmpty { body["out_path"] = outPath }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// `POST /v1/produce/{id}/delivery`: the batch of changed fields. A knob
    /// goes out only when set (`deliveryEntry` leaves nil fields out the same
    /// way); `loudness_lufs` re-targets the file's loudness without a render.
    public static func deliveryBody(entries: [DeliveryEntry], loudness: Double?) -> Data {
        var body: [String: Any] = ["chunks": entries.map { e in
            var entry: [String: Any] = ["n": e.n]
            if let style = e.style { entry["style"] = style }
            if let pauseAfter = e.pauseAfter { entry["pause_after"] = pauseAfter }
            if let pace = e.pace { entry["pace"] = pace }
            return entry
        }]
        if let loudness { body["loudness_lufs"] = loudness }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// `POST /v1/produce/{id}/chunks/{n}`: one action plus its fields.
    public static func chunkBody(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The daemon's cap on a script (produce.go maxProduceChars), about 48 minutes of speech.
    public static let scriptLimit = 40000

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

    public typealias Text = (L10nKey) -> String

    public static func waitingForServiceText(text: Text = { $0.text }) -> String { text(.produceWaitingService) }

    /// The menu's progress row: `“Title” — 3 of 10 parts`, or why it is not moving.
    /// `serviceWaiting`: the last poll got no answer, so the numbers may be old.
    public static func progressRow(_ job: ProduceJob, serviceWaiting: Bool = false, text: Text = { $0.text }) -> String {
        let name = job.title.isEmpty ? text(.produceDefaultName) : "“\(job.title)”"
        return "\(name) — \(serviceWaiting ? waitingForServiceText(text: text) : progressDetail(job, text: text))"
    }

    private static func progressDetail(_ job: ProduceJob, text: Text) -> String {
        switch job.status {
        case .pausedOnBattery: return text(.producePausedBattery)
        case .waitingForDictation: return text(.producePausedDictating)
        case .review: return String(format: text(.produceReadyListen), listenText(job.partsToReview, sentence: false, text: text))
        case .done: return text(.produceReady)
        case .failed: return text(.produceFailed)
        case .cancelled: return text(.produceStopped)
        case .interrupted: return text(.produceInterrupted)
        case .running, .unknown:
            return job.partsTotal > 0 ? String(format: text(.produceParts), String(job.partsDone), String(job.partsTotal)) : text(.produceStarting)
        }
    }

    /// "1 part needs a listen" in the two places it appears: continuing a progress row after a dash (`sentence` false: Russian
    /// starts it lower case), or as a sentence of its own in the finish alert (`sentence` true: it starts a capital).
    private static func listenText(_ count: Int, sentence: Bool, text: Text) -> String {
        if sentence { return count == 1 ? text(.produceFinishListenOne) : String(format: text(.produceFinishListenMany), String(count)) }
        return count == 1 ? text(.produceListenOne) : String(format: text(.produceListenMany), String(count))
    }

    /// The alert for a job that ended; nil for one that was stopped on purpose. A failure's own reason is the daemon's text.
    public static func finishAlert(_ job: ProduceJob, text: Text = { $0.text }) -> (title: String, text: String)? {
        switch job.status {
        case .done, .review:
            let file = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? text(.produceFinishDefaultFile)
            var saved = String(format: text(.produceFinishSaved), file)
            if job.status == .review {
                saved += " \(listenText(job.partsToReview, sentence: true, text: text)). \(text(.produceFinishInFolder))"
            }
            return (text(.produceFinishReadyTitle), saved)
        case .failed:
            return (text(.produceFinishFailedTitle), job.error ?? text(.produceFinishFailedText))
        case .interrupted:
            return (text(.produceFinishInterruptedTitle), text(.produceFinishInterruptedText))
        case .cancelled, .running, .waitingForDictation, .pausedOnBattery, .unknown:
            return nil
        }
    }
}
