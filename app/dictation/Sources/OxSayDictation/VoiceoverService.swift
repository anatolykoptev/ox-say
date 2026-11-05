import DictationCore
import Foundation

/// The one owner of the voiceover the app follows. The Studio menu and the Озвучка page share it: a project started in
/// either is followed to its end by the same `VoiceoverFollower` (its polls survive daemon outages and an app that came
/// back mid-run), and the version handshake reads `following` so a restart never cuts a running project.
/// Used from the main thread only, like the follower it owns.
final class VoiceoverService {
    private let client: StudioClient
    private var follower: VoiceoverFollower!
    private var changeObservers: [() -> Void] = []
    private var finishObservers: [(ProduceJob) -> Void] = []
    private var windowStarted: Set<String> = []

    init(client: StudioClient) {
        self.client = client
        follower = VoiceoverFollower(
            source: VoiceoverFollower.Source(voiceover: { [client] in try await client.voiceover(id: $0) },
                                             voiceovers: { [client] in try await client.voiceovers() }),
            onChange: { [weak self] in self?.changeObservers.forEach { $0() } },
            onFinish: { [weak self] job in self?.finishObservers.forEach { $0(job) } })
    }

    /// Called after the followed job changes (a poll, a start, a forgotten job).
    func observe(onChange: @escaping () -> Void, onFinish: @escaping (ProduceJob) -> Void) {
        changeObservers.append(onChange)
        finishObservers.append(onFinish)
    }

    /// The voiceover being followed, as last seen.
    var job: ProduceJob? { follower.job }
    /// The last poll got no answer: `job` may be out of date.
    var serviceWaiting: Bool { follower.serviceWaiting }
    /// A voiceover the app follows has not reached a terminal state: the version handshake waits for it.
    var following: Bool { follower.following }

    /// Whether the project was started on the Озвучка page (the page shows its end itself).
    func startedOnPage(_ id: String) -> Bool { windowStarted.contains(id) }

    /// Starts a voiceover and follows it. The daemon runs one at a time: a second start throws `voiceoverRunning`.
    @discardableResult
    func start(script: String, title: String, voice: String?, format: ProduceFormat,
               options: VoiceoverOptions = VoiceoverOptions(), fromWindow: Bool = false) async throws -> ProduceJob {
        let started = try await client.startVoiceover(script: script, title: title, voice: voice, format: format, options: options)
        if fromWindow { windowStarted.insert(started.id) }
        follower.follow(started)
        return started
    }

    /// The daemon answered /status: look for a voiceover already running (the app quit and came back).
    func serviceAnswered() { follower.serviceAnswered() }

    func stop() async throws {
        guard let job = follower.job else { return }
        try await client.stopVoiceover(id: job.id)
    }

    func continueOnBattery() async throws {
        guard let job = follower.job else { return }
        try await client.continueOnBattery(id: job.id)
    }
}
