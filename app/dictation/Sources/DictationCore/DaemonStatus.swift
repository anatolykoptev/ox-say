import Foundation

/// The parts of the daemon's `GET /status` the app reads: its build version and
/// whether the studio voice (voxcpm2) can run. Decoded by hand so an added or
/// missing field never fails the whole answer.
public struct DaemonStatus: Equatable {
    /// The daemon's build tag as it reports it ("v0.1.21"); nil when absent or empty.
    public var version: String?
    /// False when the daemon says so or says nothing: a daemon from before the
    /// studio voice cannot run it either.
    public var studioAvailable: Bool
    /// The daemon's plain-words reason the studio voice cannot run, when it gives one.
    public var studioReason: String?
    /// The daemon's machine-readable reason: "model_missing" (an install adds it)
    /// or "unsupported" (this Mac cannot run it); nil from a daemon without the field.
    public var studioReasonCode: String?
    /// The daemon's own busy report: false while any lane it counts — a
    /// produce job, a dictation session, a speech or a design — is in
    /// flight. True when the field is absent: a daemon that predates it
    /// reports nothing, and guessing "busy" would pin the version
    /// handshake's actions forever.
    public var idle: Bool

    public init(version: String?, studioAvailable: Bool, studioReason: String? = nil, studioReasonCode: String? = nil,
                idle: Bool = true) {
        self.version = version
        self.studioAvailable = studioAvailable
        self.studioReason = studioReason
        self.studioReasonCode = studioReasonCode
        self.idle = idle
    }

    public static let reasonModelMissing = "model_missing"

    /// Whether "Install Studio Voice" can help: the daemon says the engine or model
    /// is missing, or says nothing at all (a daemon from before the studio voice).
    /// A reason without that code — "unsupported", or one this app does not know —
    /// is never answered with a 3 GB download.
    public var installWouldHelp: Bool {
        if studioAvailable { return false }
        if let studioReasonCode { return studioReasonCode == Self.reasonModelMissing }
        return studioReason == nil
    }

    /// nil when `data` is not a JSON object.
    public static func decode(_ data: Data) -> DaemonStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let studio = obj["voxcpm2"] as? [String: Any]
        return DaemonStatus(version: nonEmpty(obj["version"] as? String),
                            studioAvailable: studio?["available"] as? Bool ?? false,
                            studioReason: nonEmpty(studio?["reason"] as? String),
                            studioReasonCode: nonEmpty(studio?["reason_code"] as? String),
                            idle: obj["idle"] as? Bool ?? true)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// The line at the bottom of the menu.
public enum MenuFooter {
    /// "Version 0.1.21"; "v0.1.21" and "0.1.21" are the same version.
    public static func text(appVersion: String) -> String {
        "Version \(UpdateInstaller.normalized(appVersion))"
    }
}

public enum AboutInfo {
    public static let tagline = "Dictation and voiceover on your Mac. Everything runs on this computer."
    public static let repositoryURL = "https://github.com/anatolykoptev/ox-say"

    /// The credits lines above the link: what the app is, the service it talks
    /// to and the two permissions, in plain words.
    public static func lines(serviceVersion: String?, microphoneAllowed: Bool, accessibilityAllowed: Bool) -> [String] {
        let service = serviceVersion.map { "Service: v\(UpdateInstaller.normalized($0))" } ?? "Service: not reachable"
        return [tagline, service,
                "Microphone: \(microphoneAllowed ? "allowed" : "not allowed")",
                "Accessibility: \(accessibilityAllowed ? "allowed" : "not allowed")"]
    }
}
