import Foundation

/// The daemon calls the cleanup bar makes, as closures so a test drives the session without a daemon.
public struct CleanOps {
    /// The picked file, where the result goes, whether it may replace a file there, the picked file's length when known.
    public var clean: (URL, URL, Bool, Double?) async throws -> CleanResult
    /// The recording's duration, measured locally; nil when it cannot be (the request timeout then has its floor).
    public var duration: (URL) async -> Double?

    public init(clean: @escaping (URL, URL, Bool, Double?) async throws -> CleanResult,
                duration: @escaping (URL) async -> Double? = { _ in nil }) {
        self.clean = clean
        self.duration = duration
    }
}

/// The cleanup bar's decisions. The app copies `state` into the window's values.
///
/// - one file at a time, and none while the cleaner is unavailable;
/// - a failure changes nothing but the sentence it returns, and a failed or finished job leaves the next one free to start;
/// - a cancel stops the request (the daemon stops the job when the connection closes) and is never reported as a failure;
/// - the job outlives the window: nothing here is tied to the page.
@MainActor
public final class CleanSession {
    public private(set) var working: CleanWork?
    public private(set) var done: CleanDone?
    public private(set) var failure: String?
    public private(set) var status: DaemonStatus?
    /// Called after every change of the above.
    public var onChange: () -> Void = {}

    /// How long after a cancel the daemon may still be stopping the job (its kill grace is 5 s, the job's own wind-down a
    /// little more): a `busy` answer inside it is that, not another file.
    static let cancelSettle: TimeInterval = 10

    private let ops: CleanOps
    private let text: (L10nKey) -> String
    private let now: () -> Date
    private var job: Task<Void, Never>?
    private var cancelledAt: Date?

    public init(ops: CleanOps, text: @escaping (L10nKey) -> String = { $0.text }, now: @escaping () -> Date = Date.init) {
        self.ops = ops
        self.text = text
        self.now = now
    }

    public var state: CleanActionState {
        CleanActionState.of(status: status, working: working, done: done, error: failure, text: text)
    }

    /// A cleanup is on its way: the version handshake waits for it.
    public var isWorking: Bool { working != nil }

    public func sentence(_ error: Error) -> String {
        if let error = error as? CleanError {
            // The daemon stays busy for a few seconds after a cancel: say that, not "another file is being cleaned".
            if error.problem == .busy, let cancelledAt, now().timeIntervalSince(cancelledAt) < Self.cancelSettle {
                return text(.cleanErrBusyAfterCancel)
            }
            return error.problem.sentence(text: text)
        }
        return StudioError.plain(error, text: text)
    }

    /// The daemon's last `/status`.
    public func statusRead(_ status: DaemonStatus?) {
        self.status = status
        // A failure that said "the model is downloading" must not outlive the download it was about.
        if status?.voiceClean?.installing == true { failure = nil }
        onChange()
    }

    /// Starts cleaning `input` into `output`. Returns the sentence to show when it did not start; nil when it did.
    @discardableResult
    public func start(input: URL, output: URL, overwrite: Bool) -> String? {
        if working != nil { return CleanProblem.busy.sentence(text: text) }
        if case .unavailable(let reason) = state { return reason }
        working = CleanWork(name: output.lastPathComponent)
        done = nil
        failure = nil
        onChange()
        job = Task { @MainActor [weak self] in
            await self?.run(input: input, output: output, overwrite: overwrite)
        }
        return nil
    }

    private func run(input: URL, output: URL, overwrite: Bool) async {
        let seconds = await ops.duration(input)
        var outcome: Result<CleanResult, Error>
        do {
            outcome = .success(try await ops.clean(input, output, overwrite, seconds))
        } catch {
            outcome = .failure(error)
        }
        working = nil
        job = nil
        switch outcome {
        case .success(let result):
            done = CleanDone(inputPath: input.path, outputPath: result.outPath, video: result.video, seconds: result.inputSeconds)
        case .failure(let error):
            // A job the person cancelled is not a failure, whatever the transport said when the connection closed.
            if !(error is CancellationError), !Task.isCancelled { failure = sentence(error) }
        }
        onChange()
    }

    /// Stops the running job. The bar says so until the request has ended; a result that lands first still counts.
    public func cancel() {
        guard var work = working, !work.cancelling else { return }
        work.cancelling = true
        working = work
        cancelledAt = now()
        job?.cancel()
        onChange()
    }

    /// Closes a finished job or a failure and returns to the start.
    public func dismiss() {
        guard working == nil else { return }
        done = nil
        failure = nil
        onChange()
    }
}
