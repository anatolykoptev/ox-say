import Foundation

/// How the app installs an update. The commands are built here, not inline in
/// the AppDelegate, so a regression to `curl … | sh` — where a failed download
/// hands sh an empty stdin and the pipeline exits 0 — fails a test.
public enum UpdateInstaller {
    public static let scriptURL = "https://raw.githubusercontent.com/anatolykoptev/ox-say/main/get.sh"

    /// Step 1: download get.sh to `file`. argv, never a shell string: curl's own
    /// exit status is the step's result, with no pipeline to swallow it.
    /// What step 1 downloads is get.sh itself (6,989 bytes on 2026-10-28; the 33 MB
    /// release tarball is fetched later by get.sh, not by this step). So the bound
    /// is generous for a poor line yet short enough to be a failure notice, not
    /// a hang: curl gives up on connecting after 15 s and on the whole transfer
    /// after 60 s. That is a floor of about 117 B/s for get.sh; a line slower than
    /// that times out here, as it would long before the tarball finished.
    public static let downloadConnectTimeout: TimeInterval = 15
    public static let downloadMaxTime: TimeInterval = 60
    /// The app-side kill if curl itself does not honour its bound (a stalled
    /// resolver, a wedged process): after curl's own limit, so curl's exit
    /// status (28) wins whenever it works.
    public static let downloadBackstop: TimeInterval = 90
    /// curl's exit status for an operation that ran past `--max-time` (or a connect/read timeout).
    static let curlTimedOutStatus: Int32 = 28
    /// A script starts with `#!`: two bytes.
    public static let scriptHeadLength = 2
    public static func downloadCommand(to file: String, from source: String = scriptURL) -> [String] {
        ["/usr/bin/curl", "-fsSL",
         "--connect-timeout", String(Int(downloadConnectTimeout)), "--max-time", String(Int(downloadMaxTime)),
         "-o", file, source]
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

    /// Tells the installer that the app starting it relaunches itself: install-app.sh
    /// then neither stops the running copy nor opens the new one, and a dictation
    /// is never killed by the install. The variable travels app → get.sh →
    /// install-release.sh → install-app.sh by plain environment inheritance.
    public static let appRelaunchesVariable = "OX_SAY_APP_RELAUNCHES"

    /// What an install is for.
    public enum Kind: Equatable {
        /// Check for Updates: the pinned install.
        case update
        /// Install Studio Voice: the same pinned install with the studio voice switched on.
        case studioVoice
    }

    /// Step 2 of an install, and the one place that decides between an update and
    /// the studio voice: the AppDelegate runs whatever this returns.
    public static func command(kind: Kind, script file: String, tag: String) -> Command {
        let argv = installCommand(script: file, tag: tag)
        switch kind {
        case .update: return Command(argv: argv, environment: [appRelaunchesVariable: "1"])
        case .studioVoice: return Command(argv: argv, environment: [studioVoiceVariable: "1", appRelaunchesVariable: "1"])
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
        /// `seconds` is the app-side backstop that fired; nil for curl's own exit 28, which both `--max-time` and
        /// `--connect-timeout` produce, so the limit that ran out is not known.
        case downloadTimedOut(seconds: TimeInterval?)
        case downloaderCouldNotStart(String)
        case notAScript
        case installerFailed(status: Int32)
        case couldNotStart(String)
        case versionUnchanged(expected: String, found: String?)
        /// The bundle updated but the daemon never reported the target on /status.
        case daemonNotOnVersion(expected: String, found: String?)

        /// The reason, in the user's language: `text` resolves a key (the bundle's by default, the shipped strings in
        /// tests). The system's own error text inside `why` stays as the system wrote it.
        public func message(text: (L10nKey) -> String = { $0.text }) -> String {
            func fill(_ key: L10nKey, _ args: String...) -> String { String(format: text(key), arguments: args) }
            switch self {
            case .downloadFailed(let status):
                return fill(.updateFailedDownload, String(status))
            case .downloadTimedOut(let seconds):
                return seconds.map { fill(.updateFailedDownloadTimeoutAfter, String(Int($0))) }
                    ?? text(.updateFailedDownloadTimeout)
            case .downloaderCouldNotStart(let why):
                return fill(.updateFailedDownloadStart, why)
            case .notAScript:
                return text(.updateFailedNotScript)
            case .installerFailed(let status):
                return fill(.updateFailedInstallerExit, String(status))
            case .couldNotStart(let why):
                return fill(.updateFailedInstallerStart, why)
            case .versionUnchanged(let expected, let found):
                guard let found else { return fill(.updateFailedVersionUnreadable, expected) }
                return fill(.updateFailedVersionUnchanged, expected, "v\(UpdateInstaller.normalized(found))")
            case .daemonNotOnVersion(let expected, let found):
                guard let found else { return fill(.updateFailedDaemonSilent, expected) }
                return fill(.updateFailedDaemonVersion, expected, "v\(UpdateInstaller.normalized(found))")
            }
        }

        /// The alert's body: the reason, then where the installer's output went.
        public func alertText(logPath: String, text: (L10nKey) -> String = { $0.text }) -> String {
            String(format: text(.updateFailedLogPointer), message(text: text), logPath)
        }
    }

    /// The pill that stays up while an install runs.
    public static func installingPill(kind: Kind, tag: String, text: (L10nKey) -> String = { $0.text }) -> String {
        switch kind {
        case .update: return String(format: text(.updateInstallingPill), tag)
        case .studioVoice: return text(.updateInstallingStudioPill)
        }
    }

    /// The failed alert's title.
    public static func failureTitle(kind: Kind, tag: String, text: (L10nKey) -> String = { $0.text }) -> String {
        switch kind {
        case .update: return String(format: text(.updateFailedTitle), tag)
        case .studioVoice: return text(.updateFailedTitleStudio)
        }
    }

    /// The daemon wait after an install: up to 40 polls half a second apart,
    /// each poll bounded by its own short request timeout (curl -m 2 in the
    /// shell installer's oxs_wait_version). A daemon that is down answers
    /// "refused" at once, so the wait is then about 20 s; one that accepts
    /// and never answers costs the full request timeout per poll, so the hard
    /// bound is checks x (daemonCheckTimeout + interval) - interval, about
    /// 100 s.
    public static let daemonChecks = 40
    public static let daemonCheckInterval: TimeInterval = 0.5
    /// The /status request timeout for one poll of the wait.
    public static let daemonCheckTimeout: TimeInterval = 2

    /// After a "successful" install: nil when the app on disk reports the
    /// target tag AND the daemon's /status reaches the target within the wait.
    /// `daemonVersion` re-reads /status on every poll (the caller bounds each
    /// request by `daemonCheckTimeout`); a nil answer means the daemon did
    /// not respond. There is no pause after the last poll, and a cancelled
    /// task stops the wait where it stands. Otherwise the failure to show
    /// instead of relaunching.
    public static func verifyInstalled(version: String?, daemonVersion: () async -> String?, target: String,
                                       checks: Int = daemonChecks,
                                       interval: TimeInterval = daemonCheckInterval,
                                       sleep: (TimeInterval) async throws -> Void = { seconds in
                                           try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                       }) async -> Failure? {
        guard let version, normalized(version) == normalized(target) else {
            return .versionUnchanged(expected: target, found: version)
        }
        var found: String?
        for poll in 0..<checks {
            if Task.isCancelled { break }
            if let got = await daemonVersion() {
                found = got
                if normalized(got) == normalized(target) { return nil }
            }
            guard poll < checks - 1 else { break }
            do { try await sleep(interval) } catch { break }
        }
        return .daemonNotOnVersion(expected: target, found: found)
    }

    /// The whole install: downloads get.sh from `scriptSource`, checks it is a
    /// script, runs it for `kind` pinned to `tag`, then asks `installedVersion`
    /// (the version the bundle on disk now reports) and `daemonVersion` (the
    /// daemon's /status) whether the target arrived.
    /// Two steps, each exit status checked (a `curl | sh` pipe would report the
    /// shell's 0 for a failed download). nil on success; otherwise the first step
    /// that failed. Output of both steps goes to `log`.
    public static func run(kind: Kind, tag: String, log: FileHandle?, scriptSource: String = scriptURL,
                           downloadBackstop: TimeInterval = downloadBackstop,
                           downloadArgv: (String, String) -> [String] = { downloadCommand(to: $0, from: $1) },
                           installedVersion: () -> String?,
                           daemonVersion: () async -> String?) async -> Failure? {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-get-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }

        let download = Command(argv: downloadArgv(script.path, scriptSource), environment: [:])
        switch await runProcess(download, log: log, timeout: downloadBackstop) {
        case .failure(is ProcessTimedOut): return .downloadTimedOut(seconds: downloadBackstop)
        case .failure(let error): return .downloaderCouldNotStart(error.localizedDescription)
        case .success(let status) where status == curlTimedOutStatus: return .downloadTimedOut(seconds: nil)
        case .success(let status) where status != 0: return .downloadFailed(status: status)
        case .success: break
        }
        let head = (try? FileHandle(forReadingFrom: script)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: scriptHeadLength)
        } ?? Data()
        guard isScript(head: head) else { return .notAScript }

        switch await runProcess(command(kind: kind, script: script.path, tag: tag), log: log) {
        case .failure(let error): return .couldNotStart(error.localizedDescription)
        case .success(let status) where status != 0: return .installerFailed(status: status)
        case .success: break
        }
        return await verifyInstalled(version: installedVersion(), daemonVersion: daemonVersion, target: tag)
    }

    /// Runs one command with stdout and stderr in the log; the result is its exit
    /// status, or the error when it could not start. The command's own variables
    /// are added to the app's environment.
    static func runProcess(_ command: Command, log: FileHandle?, timeout: TimeInterval? = nil) async -> Result<Int32, Error> {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: command.argv[0])
            p.arguments = Array(command.argv.dropFirst())
            p.environment = command.launchEnvironment(base: ProcessInfo.processInfo.environment)
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = log ?? FileHandle.nullDevice
            p.standardError = log ?? FileHandle.nullDevice
            p.terminationHandler = { _ = once.resume(.success($0.terminationStatus)) }
            do {
                try p.run()
            } catch {
                // Never launched: no termination handler will fire, and nothing may wait on it.
                _ = once.resume(.failure(error))
                return
            }
            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Only the timeout that wins the race ends the process.
                if once.resume(.failure(ProcessTimedOut())), p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// `runProcess` ran past its timeout and the process was killed.
    struct ProcessTimedOut: Error {}

    /// Resumes a continuation at most once: a process's termination, a launch
    /// failure and a timeout can each try, and the first one wins.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<Int32, Error>, Never>?

        init(_ continuation: CheckedContinuation<Result<Int32, Error>, Never>) { self.continuation = continuation }

        /// True when this call was the one that resumed.
        func resume(_ result: Result<Int32, Error>) -> Bool {
            lock.lock()
            let taken = continuation
            continuation = nil
            lock.unlock()
            taken?.resume(returning: result)
            return taken != nil
        }
    }
}

/// Whether Check for Updates may start while an install is running.
public enum UpdateGate: Equatable {
    case proceed
    case installInProgress

    public static func busyAlertTitle(text: (L10nKey) -> String = { $0.text }) -> String { text(.updateBusyTitle) }
    public static func busyAlertText(text: (L10nKey) -> String = { $0.text }) -> String { text(.updateBusyText) }

    public static func decide(installing: Bool) -> UpdateGate {
        installing ? .installInProgress : .proceed
    }
}

/// Which copy of the app is "the installed one". get.sh installs to
/// ~/Applications/OxSayDictation.app; a copy run from a download folder or a
/// disk image is not it, and its own Info.plist says nothing about what the
/// installer just wrote.
public enum InstalledApp {
    public static let bundleName = "OxSayDictation.app"

    /// The installed bundle when it is there (its Info.plist exists) and not older than the running one, otherwise
    /// the bundle this process runs from: a dev build or a copy run from a download folder next to an old
    /// ~/Applications copy must not be offered a "repair" down to it. A version that cannot be read sorts oldest
    /// (`UpdateChecker.isNewer`), so an unreadable installed copy is never preferred to a readable running one.
    /// `version` reads a bundle's `CFBundleShortVersionString` from its Info.plist file.
    public static func bundleURL(running: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                                 version: (URL) -> String? = plistVersion(of:)) -> URL {
        let installed = home.appendingPathComponent("Applications").appendingPathComponent(bundleName)
        guard exists(installed.appendingPathComponent("Contents/Info.plist")) else { return running }
        let installedVersion = version(installed) ?? ""
        let runningVersion = version(running) ?? ""
        return UpdateChecker.isNewer(runningVersion, than: installedVersion) ? running : installed
    }

    /// The version in the bundle's Info.plist FILE, never `Bundle`, which caches the plist a process launched with.
    public static func plistVersion(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
    }
}

/// The "Installing…" pill and a notice that replaces it.
public enum InstallPill {
    /// When a notice's pill times out: the install pill goes back up instead of
    /// the overlay hiding, while the install runs and no dictation owns the pill.
    public static func restoreAfterNotice(installing: Bool, dictation: DictationState) -> Bool {
        installing && dictation == .idle
    }
}
