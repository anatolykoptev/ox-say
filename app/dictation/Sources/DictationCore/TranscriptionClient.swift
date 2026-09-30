import Foundation

public enum TranscriptionError: Error, Equatable, CustomStringConvertible {
    case daemonUnreachable(String)
    case timedOut
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .daemonUnreachable(let why): return "The ox-say daemon is not reachable (\(why)). Is it running? Try `ox-say status`."
        case .timedOut: return "The ox-say daemon took too long to answer. It may be busy with a long transcription."
        case .http(let code, let body): return "The ox-say daemon answered \(code): \(body)"
        case .badResponse: return "The ox-say daemon sent a response without text."
        }
    }
}

/// Sends a recording to the ox-say daemon's OpenAI-compatible
/// `POST /v1/audio/transcriptions` and returns the text.
public struct TranscriptionClient {
    public typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    public var baseURL: URL
    public var model: String
    public var send: Send

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8094")!, model: String = "parakeet",
                send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.model = model
        self.send = send
    }

    /// Transcribes 16 kHz mono samples.
    public func transcribe(_ samples: [Float]) async throws -> String {
        let boundary = "ox-say-dictation-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(WAV.pcm16(samples, sampleRate: 16000))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Longer than the daemon's own per-transcription cap (600 s): a request
        // queued behind a long transcription is slow, not lost.
        request.timeoutInterval = 660

        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.timedOut
        } catch {
            throw TranscriptionError.daemonUnreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranscriptionError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw TranscriptionError.badResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
