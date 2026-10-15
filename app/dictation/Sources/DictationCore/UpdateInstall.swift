import Foundation

/// How the app installs an update. The commands are built here, not inline in
/// the AppDelegate, so a regression to `curl … | sh` — where a failed download
/// hands sh an empty stdin and the pipeline exits 0 — fails a test.
public enum UpdateInstaller {
    public static let scriptURL = "https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh"

    /// Step 1: download get.sh to `file`. argv, never a shell string: curl's own
    /// exit status is the step's result, with no pipeline to swallow it.
    public static func downloadCommand(to file: String, from source: String = scriptURL) -> [String] {
        ["/usr/bin/curl", "-fsSL", "-o", file, source]
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

        /// The environment the process starts with: `base` plus this command's variables.
        public func launchEnvironment(base: [String: String]) -> [String: String] {
            base.merging(environment) { _, new in new }
        }
    }

    /// The installer's switch for the studio voice model (about 3 GB).
    public static let studioVoiceVariable = "OX_SAY_WITH_VOXCPM2"

    /// What an install is for.
    public enum Kind: Equatable {
        /// Check for Updates: the pinned install, no extra environment.
        case update
        /// Install Studio Voice: the same pinned install with the studio voice switched on.
        case studioVoice
    }

    /// Step 2 of an install, and the one place that decides between an update and
    /// the studio voice: the AppDelegate runs whatever this returns.
    public static func command(kind: Kind, script file: String, tag: String) -> Command {
        let argv = installCommand(script: file, tag: tag)
        switch kind {
        case .update: return Command(argv: argv, environment: [:])
        case .studioVoice: return Command(argv: argv, environment: [studioVoiceVariable: "1"])
        }
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

    /// The whole install: downloads get.sh from `scriptSource`, checks it is a
    /// script, runs it for `kind` pinned to `tag`, then asks `installedVersion`
    /// (the version the bundle on disk now reports) whether the target arrived.
    /// Two steps, each exit status checked (a `curl | sh` pipe would report the
    /// shell's 0 for a failed download). nil on success; otherwise the first step
    /// that failed. Output of both steps goes to `log`.
    public static func run(kind: Kind, tag: String, log: FileHandle?, scriptSource: String = scriptURL,
                           installedVersion: () -> String?) async -> Failure? {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-get-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }

        let download = Command(argv: downloadCommand(to: script.path, from: scriptSource), environment: [:])
        switch await runProcess(download, log: log) {
        case .failure(let error): return .couldNotStart(error.localizedDescription)
        case .success(let status) where status != 0: return .downloadFailed(status: status)
        case .success: break
        }
        let head = (try? FileHandle(forReadingFrom: script)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 2)
        } ?? Data()
        guard isScript(head: head) else { return .notAScript }

        switch await runProcess(command(kind: kind, script: script.path, tag: tag), log: log) {
        case .failure(let error): return .couldNotStart(error.localizedDescription)
        case .success(let status) where status != 0: return .installerFailed(status: status)
        case .success: break
        }
        return verifyInstalled(version: installedVersion(), target: tag)
    }

    /// Runs one command with stdout and stderr in the log; the result is its exit
    /// status, or the error when it could not start. The command's own variables
    /// are added to the app's environment.
    static func runProcess(_ command: Command, log: FileHandle?) async -> Result<Int32, Error> {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command.argv[0])
            p.arguments = Array(command.argv.dropFirst())
            p.environment = command.launchEnvironment(base: ProcessInfo.processInfo.environment)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = log ?? FileHandle.nullDevice
            p.standardError = log ?? FileHandle.nullDevice
            p.terminationHandler = { continuation.resume(returning: .success($0.terminationStatus)) }
            do {
                try p.run()
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
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
