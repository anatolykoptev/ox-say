import Foundation

public enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
    /// The models are missing, incomplete or will not load.
    case models = 3
    /// The audio file is missing or unreadable.
    case input = 4
    /// macOS older than the floor below.
    case unsupportedOS = 5
    /// The output cannot be written where the caller asked: it exists, another run holds its `.part`, the directory is
    /// missing or not writable, the path names a directory, or the destination cannot take the file. Processing errors stay 1.
    case output = 6
}

public enum Platform {
    /// Engine floor. The app itself runs on 14.2, but nothing below 15 has been measured for this model.
    public static let minimumMajor = 15

    /// The macOS major version the gate judges. OX_CLEAN_ASSUME_MACOS can only LOWER the real version, so a CI
    /// runner on macOS 15 can exercise the refusal and nobody can use the variable to get past it.
    public static func osMajor() -> Int {
        effectiveVersion(real: ProcessInfo.processInfo.operatingSystemVersion,
                         assume: ProcessInfo.processInfo.environment["OX_CLEAN_ASSUME_MACOS"]).majorVersion
    }

    public static func supported() -> Bool { osMajor() >= minimumMajor }

    /// One plain sentence for the refusal, nil when this macOS is supported.
    public static func refusal() -> String? {
        let major = osMajor()
        guard major < minimumMajor else { return nil }
        return "ox-clean needs macOS \(minimumMajor) or later; this is macOS \(major)"
    }

    /// "14", "14.8" or "14.8.1" lowers the real version; anything else (empty, junk, a fourth component, a negative
    /// number) is ignored as a whole rather than half-parsed.
    static func effectiveVersion(real: OperatingSystemVersion, assume: String?) -> OperatingSystemVersion {
        guard let assume else { return real }
        let parts = assume.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return real }
        let n = parts.map { $0! }
        let wanted = OperatingSystemVersion(majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0,
                                            patchVersion: n.count > 2 ? n[2] : 0)
        return isLower(wanted, than: real) ? wanted : real
    }

    static func isLower(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) < (b.majorVersion, b.minorVersion, b.patchVersion)
    }
}
