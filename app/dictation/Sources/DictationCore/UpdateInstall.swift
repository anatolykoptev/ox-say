import Foundation

/// How the app installs an update. The commands are built here, not inline in
/// the AppDelegate, so a regression to `curl … | sh` — where a failed download
/// hands sh an empty stdin and the pipeline exits 0 — fails a test.
public enum UpdateInstaller {
    public static let scriptURL = "https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh"

    /// Step 1: download get.sh to `file`. argv, never a shell string: curl's own
    /// exit status is the step's result, with no pipeline to swallow it.
    public static func downloadCommand(to file: String) -> [String] {
        ["/usr/bin/curl", "-fsSL", "-o", file, scriptURL]
    }

    /// Step 2: run the downloaded script, pinned to the tag the user accepted so
    /// "latest" moving underneath cannot install a different version.
    public static func installCommand(script file: String, tag: String) -> [String] {
        ["/bin/sh", file, "--version", tag]
    }

    /// A command to run: argv, and the environment variables added to the app's own.
    public struct Command: Equatable {
        public var argv: [String]
        public var environment: [String: String]

        public init(argv: [String], environment: [String: String]) {
            self.argv = argv
            self.environment = environment
        }
    }

    /// The installer's switch for the studio voice model (about 3 GB).
    public static let studioVoiceVariable = "OX_SAY_WITH_VOXCPM2"

    /// Step 2 of an update: the pinned install, with no extra environment.
    public static func updateCommand(script file: String, tag: String) -> Command {
        Command(argv: installCommand(script: file, tag: tag), environment: [:])
    }

    /// Step 2 of "Install Studio Voice": the same pinned install with the studio
    /// voice switched on.
    public static func studioVoiceCommand(script file: String, tag: String) -> Command {
        Command(argv: installCommand(script: file, tag: tag), environment: [studioVoiceVariable: "1"])
    }

    /// The tag of the version that is installed: "0.1.21" is release "v0.1.21".
    public static func tag(forVersion version: String) -> String { "v\(normalized(version))" }

    /// A downloaded get.sh is plausible only when non-empty and starting `#!`.
    /// `head` is the file's first bytes.
    public static func isScript(head: Data) -> Bool {
        head.starts(with: Data("#!".utf8))
    }

    /// "v0.1.21" and "0.1.21" name the same version.
    static func normalized(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    /// Why an install did not produce the new version; `message` is the alert text.
    public enum Failure: Equatable {
        case downloadFailed(status: Int32)
        case notAScript
        case installerFailed(status: Int32)
        case couldNotStart(String)
        case versionUnchanged(expected: String, found: String?)

        public var message: String {
            switch self {
            case .downloadFailed(let status):
                return "Downloading the installer failed (curl exited with status \(status))."
            case .notAScript:
                return "The downloaded installer was empty or not a script."
            case .installerFailed(let status):
                return "The installer exited with status \(status)."
            case .couldNotStart(let why):
                return "The installer could not start: \(why)."
            case .versionUnchanged(let expected, let found):
                let now = found.map { "v\(UpdateInstaller.normalized($0))" } ?? "unknown"
                return "The version did not change: expected \(expected) after the install, found \(now)."
            }
        }
    }

    /// After a "successful" install: nil when the app on disk reports the target
    /// tag, otherwise the failure to show instead of relaunching.
    public static func verifyInstalled(version: String?, target: String) -> Failure? {
        if let version, normalized(version) == normalized(target) { return nil }
        return .versionUnchanged(expected: target, found: version)
    }
}

/// Whether Check for Updates may start while an install is running.
public enum UpdateGate: Equatable {
    case proceed
    case installInProgress

    public static let busyAlertTitle = "An update is already being installed."

    public static func decide(installing: Bool) -> UpdateGate {
        installing ? .installInProgress : .proceed
    }
}
