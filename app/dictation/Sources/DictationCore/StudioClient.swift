import Foundation

public enum StudioError: Error, Equatable, CustomStringConvertible {
    case daemonUnreachable
    case timedOut
    /// The daemon refused or failed; the text is its own plain-words message.
    case refused(status: Int, message: String)
    case badResponse
    /// A second voiceover was started while one runs (409 carrying `running_id`); the id is not shown.
    case voiceoverRunning
    /// Starting a project needs a saved voice and the library has none (400).
    case noSavedVoice
    /// A mood on a project made with the recording's own delivery (409 from `deliveryModeGate`): no style can apply there.
    case stylingUnavailable
    /// A small-memory Mac is busy with another large engine (a voiceover, the fast voice or meeting notes): the daemon's
    /// 503 with code `engine_busy_memory`. Nothing failed; the request can be repeated later.
    case enginesBusy

    /// What the person reads, in their language. The daemon's own words in a refusal stay as it sent them; an empty
    /// one is the app's sentence naming the status. `description` below stays English: it is for logs.
    public func message(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .daemonUnreachable: return text(.studioErrorUnreachable)
        case .timedOut: return text(.studioErrorTimedOut)
        case .refused(let status, let message): return message.isEmpty ? String(format: text(.studioErrorRefused), String(status)) : message
        case .badResponse: return text(.studioErrorBadResponse)
        case .voiceoverRunning: return text(.speakStudioBusy)
        case .noSavedVoice: return text(.speakStudioNeedsVoice)
        case .stylingUnavailable: return text(.speakMoodUnavailable)
        case .enginesBusy: return text(.speakEngineBusy)
        }
    }

    /// Any error as the person should read it: the app's own words for a StudioError, a plain fallback for the rest.
    public static func plain(_ error: Error, text: (L10nKey) -> String = { $0.text }) -> String {
        (error as? StudioError)?.message(text: text) ?? text(.studioPlainFallback)
    }

    public var description: String {
        switch self {
        case .daemonUnreachable: return "The OxSay service is not running. Try restarting your Mac."
        case .timedOut: return "The OxSay service took too long to answer."
        case .refused(let status, let message): return message.isEmpty ? "The OxSay service answered with an error (\(status))." : message
        case .badResponse: return "The OxSay service sent an answer the app does not understand."
        case .voiceoverRunning: return "Another voiceover is being produced."
        case .noSavedVoice: return "Producing a voiceover needs a saved voice."
        case .stylingUnavailable: return "This project cannot take a mood: it keeps the recording's own delivery."
        case .enginesBusy: return "Another large voice or notes engine is busy; try again later."
        }
    }
}

/// The studio features' calls to the ox-say daemon: status, long voiceovers and
/// voice design. Same address and injectable transport as SpeechClient; every
/// decision lives in the pure types next to it.
public struct StudioClient {
    public typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    /// Timeouts, seconds. A status or list read is instant on a healthy daemon.
    public static let quickTimeout: TimeInterval = 10
    /// Starting a voiceover only checks the script and launches the job.
    public static let startTimeout: TimeInterval = 30
    /// A meeting read with its notes and transcript: the daemon reads them from disk, a long call is megabytes, and it may
    /// be busy transcribing another one. The same bound as starting a job, the one middle tier here; the 660 s of a
    /// voice design is generation, not a read.
    public static let meetingTextsTimeout: TimeInterval = startTimeout
    /// Adding a voice: ffmpeg's own cap on normalizing the clip is 60 s
    /// (voices.Prepare), and a clip past the reference window is transcribed.
    public static let voiceAddTimeout: TimeInterval = 120
    public static let designTimeout: TimeInterval = 660

    public var baseURL: URL
    public var send: Send

    public init(baseURL: URL = DaemonAddress.fallback,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.send = send
    }

    /// The daemon's answer to one request: its body, or why there is none.
    func perform(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await performWithResponse(request)
        return (data, response?.statusCode ?? 200)
    }

    /// `perform` with the response itself, for the callers that read a header (Retry-After).
    func performWithResponse(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse?) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw StudioError.timedOut
        } catch {
            throw StudioError.daemonUnreachable
        }
        return (data, response as? HTTPURLResponse)
    }

    func get(_ path: String, timeout: TimeInterval = StudioClient.quickTimeout) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        return request
    }

    /// The daemon's own message from an error body (`{"error":{"message":…}}`) in plain
    /// words, or a sentence naming the status when the body has none or only jargon.
    static func refusal(status: Int, body: Data) -> StudioError {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (obj?["error"] as? [String: Any])?["message"] as? String ?? ""
        // The daemon's memory-busy answer: keyed on its JSON code, never on the English words.
        if status == 503, SpeechClient.isEnginesBusy(body: body) { return .enginesBusy }
        // The daemon's busy answer is the 409 that carries `running_id` (produce_http.go writeProduceErr): a code, not a
        // sentence. The other 409s (still cancelling, not running) carry none and keep their own words.
        if status == 409, obj?["running_id"] is String { return .voiceoverRunning }
        // "produce needs a saved voice" has no code on the wire (only type "Bad Request"), so its opening words are the one
        // text match, kept at this edge and pinned by a test; PlainWords would drop the whole sentence for its `voice_` hint.
        if status == 400, message.hasPrefix("produce needs a saved voice") { return .noSavedVoice }
        // The two delivery-gate 409s (`deliveryNeedsReference`, `deliveryIsUltimate`, produce_ops.go) carry no code on the wire
        // either, only their opening words; both mean the project keeps the recording's delivery and a mood cannot apply.
        if status == 409, message.hasPrefix("styling a phrase") { return .stylingUnavailable }
        // An empty message is the app's sentence naming the status, worded when it is shown (StudioError.message).
        return .refused(status: status, message: PlainWords.clean(message, fallback: ""))
    }

    /// GET /status: the daemon's version and whether the studio voice can run.
    /// `timeout` bounds the request; the default is the quick read every menu open uses.
    public func status(timeout: TimeInterval = StudioClient.quickTimeout) async throws -> DaemonStatus {
        let (data, status) = try await perform(get("status", timeout: timeout))
        guard (200..<300).contains(status) else { throw Self.refusal(status: status, body: data) }
        guard let decoded = DaemonStatus.decode(data) else { throw StudioError.badResponse }
        return decoded
    }

    /// A POST with a JSON body. A bare action (`body: nil`) sends `{}`: the daemon
    /// answers 415 to a POST without `Content-Type: application/json` (its CSRF
    /// guard), and URLSession sends no Content-Type for a bodiless POST.
    func post(_ path: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body ?? Data("{}".utf8)
        return request
    }

    /// Runs `request` and requires a 2xx answer; otherwise the daemon's own message.
    func succeed(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await perform(request)
        guard (200..<300).contains(status) else { throw Self.refusal(status: status, body: data) }
        return data
    }

    // MARK: long voiceovers

    /// POST /v1/produce: starts a voiceover of `script`. The daemon runs one at
    /// a time; a second start answers 409 with its message.
    public func startVoiceover(script: String, title: String, voice: String?, format: ProduceFormat,
                               options: VoiceoverOptions = VoiceoverOptions()) async throws -> ProduceJob {
        let body = ProduceRequest.createBody(script: script, title: title, voice: voice, format: format, options: options)
        let data = try await succeed(post("v1/produce", body: body, timeout: Self.startTimeout))
        guard let job = ProduceJob.decode(data) else { throw StudioError.badResponse }
        return job
    }

    /// GET /v1/produce/{id}.
    public func voiceover(id: String) async throws -> ProduceJob {
        let data = try await succeed(get("v1/produce/\(id)"))
        guard let job = ProduceJob.decode(data) else { throw StudioError.badResponse }
        return job
    }

    /// GET /v1/produce/{id}/chunks: every chunk's detail in one read — the
    /// bulk route, so a long project's detail read is one request, not N+1.
    public func chunks(id: String) async throws -> [ProduceChunkDetail] {
        let data = try await succeed(get("v1/produce/\(id)/chunks"))
        guard let chunks = Self.decodeChunks(data) else { throw StudioError.badResponse }
        return chunks
    }

    /// `{"chunks":[…]}` as the bulk route writes it. A null or missing list is
    /// an empty one, matching decodeList: the daemon marshals `[]`, never
    /// null, but an empty answer must not fail the whole read.
    static func decodeChunks(_ data: Data) -> [ProduceChunkDetail]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = obj["chunks"] as? [[String: Any]] ?? []
        return list.compactMap(ProduceChunkDetail.decode)
    }

    /// POST /v1/produce/{id}/chunks/{n} {"action":"regenerate","takes":N}:
    /// new takes of one chunk. The daemon validates and launches the job;
    /// the 202 answer is a job summary, so the write itself is fast — the
    /// same bound a create gets.
    public func regenerate(id: String, chunk: Int, takes: Int) async throws {
        _ = try await succeed(post("v1/produce/\(id)/chunks/\(chunk)",
                                   body: ProduceRequest.chunkBody(["action": "regenerate", "takes": takes]),
                                   timeout: Self.startTimeout))
    }

    /// POST /v1/produce/{id}/chunks/{n} {"action":"pick","take":KEY}: choose
    /// one of the chunk's takes — the person's own pick, kept over the checks.
    public func pick(id: String, chunk: Int, take: String) async throws {
        _ = try await succeed(post("v1/produce/\(id)/chunks/\(chunk)",
                                   body: ProduceRequest.chunkBody(["action": "pick", "take": take]),
                                   timeout: Self.startTimeout))
    }

    /// POST /v1/produce/{id}/chunks/{n} {"action":"edit","text":…}: rewrite
    /// the chunk's words; it is rendered again on the next run.
    public func editText(id: String, chunk: Int, text: String) async throws {
        _ = try await succeed(post("v1/produce/\(id)/chunks/\(chunk)",
                                   body: ProduceRequest.chunkBody(["action": "edit", "text": text]),
                                   timeout: Self.startTimeout))
    }

    /// POST /v1/produce/{id}/delivery: one batch of style/pause/pace changes,
    /// plus the file's loudness when it changed — an assemble-only run that
    /// needs no render.
    public func deliver(id: String, entries: [DeliveryEntry], loudness: Double?) async throws {
        _ = try await succeed(post("v1/produce/\(id)/delivery",
                                   body: ProduceRequest.deliveryBody(entries: entries, loudness: loudness),
                                   timeout: Self.startTimeout))
    }

    /// GET /v1/produce: the daemon's recent voiceovers, newest first.
    public func voiceovers() async throws -> [ProduceJob] {
        let data = try await succeed(get("v1/produce"))
        guard let jobs = ProduceJob.decodeList(data) else { throw StudioError.badResponse }
        return jobs
    }

    /// POST /v1/produce/{id}/cancel.
    public func stopVoiceover(id: String) async throws {
        _ = try await succeed(post("v1/produce/\(id)/cancel", body: nil, timeout: Self.quickTimeout))
    }

    /// POST /v1/produce/{id}/resume with the battery allowed.
    public func continueOnBattery(id: String) async throws {
        _ = try await succeed(post("v1/produce/\(id)/resume", body: ProduceRequest.resumeOnBatteryBody(), timeout: Self.quickTimeout))
    }

    // MARK: voice design

    /// POST /v1/audio/voices/design: renders the candidate takes. It waits for a
    /// cold engine start, any request queued ahead and three takes in a row; the
    /// daemon budgets itself 30 s + 3 x 36 s + 30 s for that, and the speak call
    /// allows 660 s for a queued request, so the same 660 s is used here.
    public func designVoice(description: String, text: String) async throws -> [DesignTake] {
        let body = DesignRequest.body(description: description, text: text)
        let data = try await succeed(post("v1/audio/voices/design", body: body, timeout: Self.designTimeout))
        guard let takes = DesignTake.decodeAll(data) else { throw StudioError.badResponse }
        return takes
    }

    /// POST /v1/audio/voices/design/save: keeps a take as a voice. A name that
    /// exists comes back as `.nameTaken`; send again with `replace` to overwrite it.
    public func saveDesign(name: String, take: String, replace: Bool) async throws -> SaveOutcome {
        let body = DesignRequest.saveBody(name: name, take: take, replace: replace)
        let (data, status) = try await perform(post("v1/audio/voices/design/save", body: body, timeout: Self.quickTimeout))
        return try SaveOutcome.interpret(status: status, data: data)
    }

    /// A PATCH with a JSON body. The daemon's Content-Type check is on POST
    /// alone, but a body always travels with its type set.
    func patch(_ path: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = post(path, body: body, timeout: timeout)
        request.httpMethod = "PATCH"
        return request
    }

    /// A bare DELETE (the route reads the voice from the path, no body).
    func delete(_ path: String, timeout: TimeInterval = StudioClient.quickTimeout) -> URLRequest {
        var request = get(path, timeout: timeout)
        request.httpMethod = "DELETE"
        return request
    }

    // MARK: the voice library

    /// A JSON request body, or `badResponse` when the object cannot be encoded
    /// (a NaN would raise an Objective-C exception in JSONSerialization, so the
    /// object is checked first): an empty POST would only come back as a 400.
    static func jsonBody(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw StudioError.badResponse }
        return data
    }

    /// GET /v1/audio/voices: the saved voices with their labels, origins and dates.
    public func voiceEntries() async throws -> [VoiceEntry] {
        let data = try await succeed(get("v1/audio/voices"))
        guard let entries = VoiceEntry.decodeList(data) else { throw StudioError.badResponse }
        return entries
    }

    /// POST /v1/audio/voices: adds the clip at `audioPath` as the voice `id`
    /// (derived from `label` by VoiceName), labelled for the person; `source`
    /// is "recorded" or "file" (voices.Meta.Source). The daemon normalizes the
    /// clip (ffmpeg, up to its 60 s cap) and may transcribe it; transcription
    /// shares the daemon's 60 s context rather than adding to it, so the call
    /// outlasts a quick read and need not outlast the daemon.
    public func addVoice(id: String, label: String, audioPath: String, refText: String, source: String) async throws -> SavedVoice {
        let body: [String: Any] = ["name": id, "audio_path": audioPath, "ref_text": refText,
                                   "label": label, "source": source]
        let data = try await succeed(post("v1/audio/voices", body: try Self.jsonBody(body), timeout: Self.voiceAddTimeout))
        guard let saved = SavedVoice.decode(data) else { throw StudioError.badResponse }
        return saved
    }

    /// PATCH /v1/audio/voices/{id}: renames the voice — the label a person
    /// sees; the on-disk id never changes.
    public func setVoiceLabel(id: String, label: String) async throws {
        let body = try Self.jsonBody(["label": label])
        _ = try await succeed(patch("v1/audio/voices/\(id)", body: body, timeout: Self.quickTimeout))
    }

    /// DELETE /v1/audio/voices/{id}.
    public func deleteVoice(id: String) async throws {
        _ = try await succeed(delete("v1/audio/voices/\(id)"))
    }
}
