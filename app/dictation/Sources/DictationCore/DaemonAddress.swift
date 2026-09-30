import Foundation

/// Where the ox-say daemon listens. The installer writes the daemon's settings
/// into its LaunchAgent, so the app reads OX_SAY_ADDR from there rather than
/// keeping a second copy of the setting that could disagree.
public enum DaemonAddress {
    public static let agentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.github.anatolykoptev.ox-say.plist")
    public static let fallback = URL(string: "http://127.0.0.1:8094")!

    /// The daemon's base URL from the LaunchAgent plist's contents; the default
    /// address when there is no plist or no OX_SAY_ADDR in it.
    public static func url(agentPlist data: Data?) -> URL {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any],
              let addr = env["OX_SAY_ADDR"] as? String else {
            return fallback
        }
        return url(listenAddress: addr) ?? fallback
    }

    /// A Go listen address ("host:port", ":port", "0.0.0.0:port", "[::1]:port")
    /// as a URL to connect to. A wildcard or missing host means this Mac.
    public static func url(listenAddress addr: String) -> URL? {
        guard let colon = addr.lastIndex(of: ":") else { return nil }
        var host = String(addr[..<colon])
        let port = String(addr[addr.index(after: colon)...])
        guard let number = Int(port), (1...65535).contains(number) else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty || host == "0.0.0.0" || host == "::" { host = "127.0.0.1" }
        guard !host.contains("/"), !host.contains("@"), !host.contains(" ") else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(bracketed):\(number)")
    }
}
