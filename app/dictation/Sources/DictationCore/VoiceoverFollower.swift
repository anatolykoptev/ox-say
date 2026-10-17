import Foundation

/// Follows the voiceover the daemon is making until it is over, across short
/// outages of the service. It stops on a terminal state or when the daemon no
/// longer knows the job (404), and on nothing else: a daemon that restarts under
/// a running job must not make the app forget it. The AppKit controller only
/// draws what this reports. Used from the main thread only: its polling runs in
/// `@MainActor` tasks.
public final class VoiceoverFollower {
    /// What the follower asks of the daemon, and of time; injectable for tests.
    public struct Source {
        public var voiceover: (String) async throws -> ProduceJob
        public var voiceovers: () async throws -> [ProduceJob]
        public var sleep: (TimeInterval) async -> Void

        public init(voiceover: @escaping (String) async throws -> ProduceJob,
                    voiceovers: @escaping () async throws -> [ProduceJob],
                    sleep: @escaping (TimeInterval) async -> Void = { seconds in
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    }) {
            self.voiceover = voiceover
            self.voiceovers = voiceovers
            self.sleep = sleep
        }
    }

    /// The longest wait between polls while the service does not answer, seconds.
    public static let maxBackoff: TimeInterval = 60
    /// Failures after which the wait stops doubling.
    private static let maxDoublings = 6

    /// Seconds to wait before the next poll: the normal interval after an answer,
    /// doubling per failure up to `maxBackoff`. Never shorter than the normal interval.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        let doubled = ProduceText.pollInterval * pow(2, Double(min(failures, maxDoublings)))
        return min(doubled, maxBackoff)
    }

    /// The voiceover being followed, until the app forgets it (404).
    public private(set) var job: ProduceJob?
    /// The last poll got no answer: `job` may be out of date.
    public private(set) var serviceWaiting = false

    private let source: Source
    private let onChange: () -> Void
    private let onFinish: (ProduceJob) -> Void
    private var polling: Task<Void, Never>?
    private var pickingUp = false

    public init(source: Source, onChange: @escaping () -> Void, onFinish: @escaping (ProduceJob) -> Void) {
        self.source = source
        self.onChange = onChange
        self.onFinish = onFinish
    }

    /// Stops following; the job stays as last seen.
    public func stop() {
        polling?.cancel()
        polling = nil
    }

    /// After `stop`, pick the polling back up — the window's reappear. A no-op
    /// while a poll loop runs, with no job, or once the job is over.
    public func resume() {
        guard polling == nil, let job, !job.status.isTerminal else { return }
        follow(job)
    }

    /// The voiceover the daemon is working on: the app's own followed job
    /// while it lives (a list answer must not take a live follow over), else
    /// the list's first non-terminal job — one started elsewhere included.
    /// nil when nothing runs. The «Озвучить» gate, a pure function of the
    /// daemon's answer.
    public static func activeJob(following: ProduceJob?, listed: [ProduceJob]) -> ProduceJob? {
        if let following, !following.status.isTerminal { return following }
        return listed.first { !$0.status.isTerminal }
    }

    /// The daemon answered /status. Check its recent voiceovers for one still
    /// running and follow it: the app may have quit and come back, the job may
    /// have been started from the menu or while this window was closed. Not a
    /// once-per-lifetime flag — a job started after a successful read is found
    /// on the next answered status.
    public func serviceAnswered() {
        guard !pickingUp else { return }
        pickingUp = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let jobs = try? await self.source.voiceovers()
            self.pickingUp = false
            guard let jobs,
                  let running = Self.activeJob(following: self.job, listed: jobs),
                  running.id != self.job?.id else { return }
            self.follow(running)
        }
    }

    public func follow(_ started: ProduceJob) {
        stop()
        job = started
        serviceWaiting = false
        onChange()
        let id = started.id
        polling = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let source = self?.source else { return }
                await source.sleep(Self.delay(afterFailures: failures))
                guard !Task.isCancelled, let self else { return }
                do {
                    let latest = try await source.voiceover(id)
                    guard !Task.isCancelled else { return }
                    failures = 0
                    self.job = latest
                    self.serviceWaiting = false
                    self.onChange()
                    if !ProduceText.shouldKeepPolling(latest) {
                        self.onFinish(latest)
                        return
                    }
                } catch StudioError.refused(status: 404, _) {
                    guard !Task.isCancelled else { return }
                    self.job = nil
                    self.serviceWaiting = false
                    self.onChange()
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failures += 1
                    self.serviceWaiting = true
                    self.onChange()
                }
            }
        }
    }
}
