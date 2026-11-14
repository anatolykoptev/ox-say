import Foundation

/// Where the daemon keeps its files ($OX_SAY_HOME), and the owner bearer it writes there. The app is not the
/// daemon's child: OX_SAY_HOME is whatever the installed LaunchAgent gives the daemon, so, like `DaemonAddress`, the
/// app reads it from that plist and falls back to the daemon's own default, never to a path of its own.
public enum DaemonHome {
    /// The daemon's default home (`config.defaultHome`): `~/Library/Application Support/ox-say`.
    public static func fallback(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userHome.appendingPathComponent("Library/Application Support/ox-say", isDirectory: true)
    }

    /// The daemon's home from the LaunchAgent plist's contents; the default when there is no plist, no OX_SAY_HOME in
    /// it, or one that is not an absolute path.
    public static func url(agentPlist data: Data?, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: Any],
              let home = env["OX_SAY_HOME"] as? String, home.hasPrefix("/") else {
            return fallback(userHome: userHome)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    /// The home for this Mac's installed daemon.
    public static func current() -> URL {
        url(agentPlist: try? Data(contentsOf: DaemonAddress.agentPlist))
    }
}

/// The owner bearer: `owner.token` under the daemon's home, 64 lowercase hex characters (what the daemon writes and
/// accepts). It is read at the moment of a request and held nowhere: not logged, not in UserDefaults, not shown.
public enum OwnerToken {
    public static let fileName = "owner.token"

    /// The token in `home`, or nil when the file is missing, unreadable or not a token the daemon would have
    /// written. The shape check also keeps a stray newline or control character out of a request header.
    public static func read(home: URL) -> String? {
        guard let raw = try? String(contentsOf: home.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.utf8.count == 64, token.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return token
    }
}
