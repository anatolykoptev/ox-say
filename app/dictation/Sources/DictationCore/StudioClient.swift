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
}
