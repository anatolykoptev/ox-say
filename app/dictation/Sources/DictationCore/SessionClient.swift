import Foundation

/// The daemon's streaming transcription session calls, on top of the same
/// injected `Send` as TranscriptionClient so tests can drive both with one
/// fake. A session is created empty, fed little-endian float32 mono PCM at
/// 16 kHz, and closed by finish (or dropped by delete). Any non-200 answer is
/// a `TranscriptionError.http`, a transport failure `.daemonUnreachable`.
public struct SessionClient {
    public typealias Send = TranscriptionClient.Send

    /// One /audio answer: the texts decoded since the previous call, and how
    /// many decodes are still pending on the server.
    public struct AudioReply: Equatable {
        public var texts: [String]
        public var pending: Int
    }

    public var baseURL: URL
    public var send: Send

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8094")!,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.baseURL = baseURL
        self.send = send
    }

    /// `POST /v1/audio/transcriptions/sessions` → the session id.
    public func create() async throws -> String {
        var req = request("v1/audio/transcriptions/sessions", method: "POST", timeout: 10)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let data = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else {
            throw TranscriptionError.badResponse
        }
        return id
    }

    /// `POST …/sessions/<id>/audio` with a raw PCM chunk (≤ 30 s).
    public func audio(id: String, pcm: Data) async throws -> AudioReply {
        var req = request("v1/audio/transcriptions/sessions/\(id)/audio", method: "POST", timeout: 10)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = pcm
        let data = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.badResponse
        }
        let texts = (obj["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return AudioReply(texts: texts, pending: obj["pending"] as? Int ?? 0)
    }

    /// `POST …/sessions/<id>/finish` → the session's whole text. The server may
    /// wait up to ~60 s for pending decodes, so the timeout is longer.
    public func finish(id: String) async throws -> String {
        var req = request("v1/audio/transcriptions/sessions/\(id)/finish", method: "POST", timeout: 90)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let data = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw TranscriptionError.badResponse
        }
        return text
    }

    /// `DELETE …/sessions/<id>`.
    public func delete(id: String) async throws {
        _ = try await perform(request("v1/audio/transcriptions/sessions/\(id)", method: "DELETE", timeout: 10))
    }

    private func request(_ path: String, method: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        return req
    }

    /// Sends the request and keeps only a 200; everything else maps onto
    /// TranscriptionError like the one-shot upload does.
    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(req)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionError.timedOut
        } catch {
            throw TranscriptionError.daemonUnreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TranscriptionError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}
