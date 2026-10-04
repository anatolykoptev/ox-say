import Foundation

public enum SpeechError: Error, Equatable, CustomStringConvertible {
    case daemonUnreachable(String)
    case timedOut
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .daemonUnreachable(let why): return "The ox-say daemon is not reachable (\(why)). Is it running? Try `ox-say status`."
        case .timedOut: return "The ox-say daemon took too long to answer. A cold voice engine start takes a while."
        case .http(let code, let body): return "The ox-say daemon answered \(code): \(body)"
        case .badResponse: return "The ox-say daemon sent a response without audio."
        }
    }
}

/// Sends text to the ox-say daemon's OpenAI-compatible `POST /v1/audio/speech`
/// and returns the audio bytes, and lists the voices registered on it.
public struct SpeechClient {
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
            throw SpeechError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["voices"] as? [[String: Any]] else {
            throw SpeechError.badResponse
        }
        return list.compactMap { $0["name"] as? String }
    }

    /// Synthesizes `text` and returns the audio bytes. A nil `voice` leaves the
    /// engine's default voice.
    public func speak(_ text: String, voice: String? = nil) async throws -> Data {
        var body: [String: Any] = ["input": text, "response_format": format]
        if let voice { body["voice"] = voice }
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
            throw SpeechError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard !data.isEmpty else { throw SpeechError.badResponse }
        return data
    }
}
