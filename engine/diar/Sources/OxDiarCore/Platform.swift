import Foundation

/// Process exit codes; the daemon maps them (internal/daemon/diarize.go).
public enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
    /// The models are missing, incomplete or will not load.
    case models = 3
    /// The audio file is missing or unreadable.
    case input = 4
    /// macOS older than 15: Apple's BNNS bug (FluidAudio issue 878) can crash a prediction there.
    case unsupportedOS = 5
}

public enum Platform {
    public static let minimumMajor = 15

    /// The macOS version the gate judges. OX_DIAR_ASSUME_MACOS ("14.8") can only LOWER the real version, so
    /// a CI runner on macOS 15 can exercise the refusal and nobody can use the variable to get past it.
    public static func effectiveVersion(real: OperatingSystemVersion, assume: String?) -> OperatingSystemVersion {
        guard let assume else { return real }
        let parts = assume.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 1, parts.count <= 3, parts.allSatisfy({ $0 >= 0 }) else { return real }
        let wanted = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                                            patchVersion: parts.count > 2 ? parts[2] : 0)
        return isLower(wanted, than: real) ? wanted : real
    }

    /// A message when this macOS cannot run the diarizer, nil when it can.
    public static func refusal(version v: OperatingSystemVersion) -> String? {
        guard v.majorVersion < minimumMajor else { return nil }
        return "ox-diar needs macOS \(minimumMajor) or later; this is macOS \(v.majorVersion).\(v.minorVersion)"
    }

    static func isLower(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) < (b.majorVersion, b.minorVersion, b.patchVersion)
    }
}
