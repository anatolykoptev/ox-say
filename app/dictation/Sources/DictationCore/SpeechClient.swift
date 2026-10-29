import Foundation

public enum SpeechError: Error, Equatable, CustomStringConvertible {
    case daemonUnreachable(String)
    case timedOut
    case http(Int, String)
    case badResponse
    /// The engine stopped a take that did not end inside its length budget (the
    /// daemon's typed `generation_runaway` error). Not worth showing as raw JSON.
    case runaway
    /// The text is over the daemon's limit; caught before the request so the person is told what to do.
    case tooLong(max: Int)
    /// The daemon answered 503: the speech engine is starting or failed to start.
    case engineUnavailable

    public var description: String {
        switch self {
        case .daemonUnreachable(let why): return "The ox-say daemon is not reachable (\(why)). Is it running? Try `ox-say status`."
        case .timedOut: return "The ox-say daemon took too long to answer. A cold voice engine start takes a while."
        case .http(let code, let body): return "The ox-say daemon answered \(code): \(body)"
        case .badResponse: return "The ox-say daemon sent a response without audio."
        case .runaway: return "The ox-say speech engine stopped a take that did not end."
        case .tooLong(let max): return "The text is longer than \(max) characters."
        case .engineUnavailable: return "The ox-say speech engine is not ready (503)."
        }
    }

    /// What the person reads, in their language. `description` stays English: it is for logs. The daemon's own words
    /// (the system's reason, a response body) stay out of the sentence; the status number is enough to report.
    public func message(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .daemonUnreachable: return text(.speechErrorUnreachable)
        case .timedOut: return text(.speechErrorTimedOut)
        case .http(let code, _): return String(format: text(.speechErrorHttp), String(code))
        case .badResponse: return text(.speechErrorBadResponse)
        case .runaway: return text(.noticeSpeechRunaway)
        case .tooLong(let max): return String(format: text(.speechErrorTooLong), String(max))
        case .engineUnavailable: return text(.speechErrorEngineUnavailable)
        }
    }

    /// Any failure of a speak request as the person should read it: the app's own words for a SpeechError, "the audio
    /// could not be played" for a failure once the clip was in hand, a plain fallback for the rest.
    public static func plain(_ error: Error, whilePlaying: Bool = false, text: (L10nKey) -> String = { $0.text }) -> String {
        if whilePlaying { return text(.playFailed) }
        return (error as? SpeechError)?.message(text: text) ?? text(.noticeErrorFallback)
    }
}

/// Sends text to the ox-say daemon's OpenAI-compatible `POST /v1/audio/speech`
/// and returns the audio bytes, and lists the voices registered on it.
public struct SpeechClient {
    /// The daemon's limit on one speak request, in characters (`maxSpeakChars` in internal/daemon/speak.go; a test pins it).
    public static let maxInputChars = 5000
    public typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    public var baseURL: URL
    public var format: String
    public var send: Send

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8094")!, format: String = "wav",
                send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.format = format
        self.send = send
    }

    /// What the daemon accepts as the text to speak. Empty and whitespace-only
    /// selections are not worth a round trip; the service turns them into an
    /// error instead.
    /// The error for a non-2xx answer: the typed runaway code in the daemon's
    /// `{"error":{"type":...}}` body becomes `.runaway`, anything else stays the
    /// raw `.http` it always was.
    static func failure(status: Int, body: Data) -> SpeechError {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = obj["error"] as? [String: Any], error["type"] as? String == "generation_runaway" {
            return .runaway
        }
        if status == 503 { return .engineUnavailable }
        return .http(status, String(decoding: body.prefix(300), as: UTF8.self))
    }

    public static func input(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Names of the voices registered on the daemon, in store order.
    public func voices() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/voices"))
        request.timeoutInterval = 10
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw SpeechError.timedOut
        } catch {
            throw SpeechError.daemonUnreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.failure(status: http.statusCode, body: data)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["voices"] as? [[String: Any]] else {
            throw SpeechError.badResponse
        }
        return list.compactMap { $0["name"] as? String }
    }

    /// Synthesizes `text` and returns the audio bytes. A nil `voice` leaves the
    /// engine's default voice; a non-nil `language` pins the request's
    /// language instead of letting the daemon infer it.
    public func speak(_ text: String, voice: String? = nil, language: String? = nil) async throws -> Data {
        // The daemon counts characters (runes) and refuses more; say so before the round trip.
        if text.unicodeScalars.count > Self.maxInputChars { throw SpeechError.tooLong(max: Self.maxInputChars) }
        // The fast engine, always: a voice that prefers voxcpm2 must not slow speak-selection down.
        var body: [String: Any] = ["input": text, "response_format": format, "model": "qwen3-tts"]
        if let voice { body["voice"] = voice }
        if let language { body["language"] = language }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A cold engine start is about 15 s on this Mac; a long text behind a
        // queued request is slow, not lost.
        request.timeoutInterval = 660

        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw SpeechError.timedOut
        } catch {
            throw SpeechError.daemonUnreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.failure(status: http.statusCode, body: data)
        }
        guard !data.isEmpty else { throw SpeechError.badResponse }
        return data
    }
}
