import Foundation

public enum StudioError: Error, Equatable, CustomStringConvertible {
    case daemonUnreachable
    case timedOut
    /// The daemon refused or failed; the text is its own plain-words message.
    case refused(status: Int, message: String)
    case badResponse

    public var description: String {
        switch self {
        case .daemonUnreachable: return "The ox-say service is not running. Try restarting your Mac."
        case .timedOut: return "The ox-say service took too long to answer."
        case .refused(_, let message): return message
        case .badResponse: return "The ox-say service sent an answer the app does not understand."
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
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw StudioError.timedOut
        } catch {
            throw StudioError.daemonUnreachable
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }

    func get(_ path: String, timeout: TimeInterval = StudioClient.quickTimeout) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        return request
    }

    /// The daemon's own message from an error body (`{"error":{"message":…}}`), or a
    /// plain sentence naming the status when the body has none.
    static func refusal(status: Int, body: Data) -> StudioError {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (obj?["error"] as? [String: Any])?["message"] as? String
        guard let message, !message.isEmpty else {
            return .refused(status: status, message: "The ox-say service answered with an error (\(status)).")
        }
        return .refused(status: status, message: message)
    }

    /// GET /status: the daemon's version and whether the studio voice can run.
    public func status() async throws -> DaemonStatus {
        let (data, status) = try await perform(get("status"))
        guard (200..<300).contains(status) else { throw Self.refusal(status: status, body: data) }
        guard let decoded = DaemonStatus.decode(data) else { throw StudioError.badResponse }
        return decoded
    }

    /// A POST with a JSON body (empty for a bare action).
    func post(_ path: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
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
    public func startVoiceover(script: String, title: String, voice: String?, format: ProduceFormat) async throws -> ProduceJob {
        let body = ProduceRequest.createBody(script: script, title: title, voice: voice, format: format)
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
}
