import Foundation

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case http(Int)
    case badResponse

    public var description: String {
        switch self {
        case .unreachable(let why): return "Update check failed (\(why))"
        case .http(let code): return "GitHub answered \(code) — try again later"
        case .badResponse: return "GitHub sent a release response without a tag"
        }
    }
}

/// The latest published GitHub release of ox-say, against the tag the app
/// bundle was built from.
public struct UpdateChecker {
    public typealias Send = (URLRequest) async throws -> (Data, URLResponse)

    public var apiURL: URL
    public var send: Send

    public init(apiURL: URL = URL(string: "https://api.github.com/repos/anatolykoptev/ox-say/releases/latest")!,
                send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.apiURL = apiURL
        self.send = send
    }

    /// The published release: "v0.1.14" tag and its web page URL.
    public func latestRelease() async throws -> (tag: String, url: URL?) {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw UpdateError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError.badResponse
        }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
        return (tag, page)
    }

    /// Version triples compare numerically: "v0.1.14" > "0.1.13". An
    /// unparsable tag (a malformed remote, never a dev build's "0.0.0")
    /// sorts oldest so a garbage tag can never prompt a false update.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        triple(local).lexicographicallyPrecedes(triple(remote))
    }

    static func triple(_ tag: String) -> [Int] {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        // A suffix like -beta1 or +build does not belong to the numeric compare.
        if let cut = t.firstIndex(where: { "-+".contains($0) }) { t = String(t[..<cut]) }
        let parts = t.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else {
            return [0, 0, -1]
        }
        return [a, b, c]
    }
}
