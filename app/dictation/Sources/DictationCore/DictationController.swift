import Foundation

public enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
}

public enum HotkeyMode: String {
    /// Record while the key is held; transcribe on release.
    case hold
    /// First press starts, second press stops and transcribes.
    case toggle
}

/// Captures 16 kHz mono audio from the microphone.
public protocol Recorder: AnyObject {
    /// Checks what can fail before any side effect (permission, an input
    /// device), so a press that cannot record opens no transcription session.
    func prepare() throws
    func start() throws
    /// Stops and returns what was recorded since `start`.
    func stop() -> [Float]
    /// Every recorded chunk, in order, from the recording thread. The
    /// controller sets it per dictation.
    var onSamples: (([Float]) -> Void)? { get set }
}

/// Delivers dictated text to the user, e.g. by pasting it where the cursor is.
public protocol TextOutput: AnyObject {
    /// Delivers the text and reports how: pasted, or left on the clipboard and
    /// why — the report reaches the timing line as `delivery=`.
    func deliver(_ text: String) -> Delivery
}

/// A transcription backend: a one-shot upload after the recording, or a
/// streaming session fed while it happens. `begin`/`cancel` come from the
/// main thread, `feed` from wherever the app pumps recorder chunks.
public protocol Transcriber: AnyObject {
    /// Prepare for a new recording (e.g. open a streaming session).
    func begin()
    /// The tag `begin` minted for the current dictation. Read it once when the
    /// dictation's chunk route opens and pass it with every chunk.
    var feedGeneration: Int { get }
    /// A chunk of 16 kHz mono samples, in recording order. `generation` is the
    /// tag `begin` minted for the dictation that recorded the chunk; a stale
    /// tag means the chunk belongs to a dead recording and is dropped.
    func feed(_ samples: [Float], generation: Int) async
    /// The recording stopped: the text for the whole recording.
    func finish(all: [Float]) async throws -> String
    /// Drop the recording: nothing will be delivered for it.
    func cancel()
    /// How the last `finish` was served. Read on the main thread right after
    /// `finish` returns, before the next `begin`.
    var finishStats: TranscriberStats { get }
}

extension Transcriber {
    public var finishStats: TranscriberStats { TranscriberStats(path: .oneShot) }
}

/// What the retry did, for the log: no text, only the fact and the wait.
public enum DaemonRetryEvent: Equatable {
    /// A transcription failed with the daemon unreachable; the wait began.
    case started
    /// The held audio was uploaded again and came back with text (possibly empty).
    case recovered(waitedMs: Int)
    /// The wait ran out without an answer, or the second upload failed too.
    case gaveUp(waitedMs: Int)
    /// The dictation was cancelled (Esc) or superseded during the wait or the upload.
    case cancelled(waitedMs: Int)

    public var line: String {
        switch self {
        case .started: return "daemon retry started"
        case .recovered(let ms): return "daemon retry recovered waited_ms=\(ms)"
        case .gaveUp(let ms): return "daemon retry gave_up waited_ms=\(ms)"
        case .cancelled(let ms): return "daemon retry cancelled waited_ms=\(ms)"
        }
    }
}

/// How a transcription that failed while its recording is still held gets a
/// second chance: a daemon that went dead mid-dictation is often just
/// restarting — an install reloads its agent, a crash is relaunched — so its
/// health is polled and the held audio is uploaded once more when it answers.
public struct DaemonRetry {
    /// The wait is capped here in system-uptime seconds (they stop while the Mac
    /// sleeps), probes included: about an
    /// agent reload, not a cold start. It ends at the first check after the
    /// budget, so it can overshoot by one probe's own timeout (3 s), no more.
    public var budget: TimeInterval
    /// Between probes.
    public var interval: TimeInterval
    /// One health probe on the daemon: true when it answered.
    public var probe: () async -> Bool
    /// Between probes; injected by tests, production sleeps.
    public var sleep: (TimeInterval) async -> Void
    /// Monotonic seconds; injected by tests, production reads the system uptime.
    public var now: () -> TimeInterval

    public init(probe: @escaping () async -> Bool,
                budget: TimeInterval = 60, interval: TimeInterval = 1,
                sleep: @escaping (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                },
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.probe = probe
        self.budget = budget
        self.interval = interval
        self.sleep = sleep
        self.now = now
    }

    /// Whether a failed transcription is worth the wait: only a daemon that did
    /// not answer at all. A timeout means the daemon is alive and busy (the
    /// client's 660 s sits above the daemon's 600 s cap, so a retry would sit
    /// another ~22 min); an HTTP error or an unreadable answer would fail the
    /// same way again. 502/503 are not restart signatures either: the daemon
    /// binds its port with every route registered, so before it is up the
    /// connect is refused (daemonUnreachable); once it is up, 503 on
    /// /v1/audio/transcriptions is a full queue (stt.ErrBusy) or a missing
    /// model, and 502 is not returned by that route at all.
    public static func worthWaiting(for error: Error) -> Bool {
        guard let failure = error as? TranscriptionError, case .daemonUnreachable = failure else { return false }
        return true
    }

    /// Polls `probe` until it answers or the budget is spent. `live` false —
    /// the dictation was cancelled or superseded — ends the wait at once:
    /// nothing is uploaded for a dead dictation. True means worth a retry.
    public func wait(live: () -> Bool) async -> Bool {
        let start = now()
        while live() {
            if await probe() { return true }
            let remaining = budget - (now() - start)
            guard remaining > 0 else { return false }
            await sleep(min(interval, remaining))
        }
        return false
    }
}

/// The one-shot path the app always had: `begin`/`feed`/`cancel` do nothing and
/// `finish` uploads the whole recording. Keeps the closure-based init working.
private final class OneShotTranscriber: Transcriber {
    private let transcribe: ([Float]) async throws -> String
    init(_ transcribe: @escaping ([Float]) async throws -> String) { self.transcribe = transcribe }
    func begin() {}
    var feedGeneration: Int { 0 }
    func feed(_: [Float], generation _: Int) async {}
    func finish(all: [Float]) async throws -> String { try await transcribe(all) }
    func cancel() {}
}

/// The key → record → transcribe → deliver cycle. It does no I/O itself: the
/// recorder, the transcription and the output are injected, so the state logic
/// is testable without a microphone or a daemon. Call it from the main thread.
public final class DictationController {
    public private(set) var state: DictationState = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }
    public var mode: HotkeyMode
    /// Recordings shorter than this are a key tap, not speech: dropped.
    public var minSeconds: Double = 0.3
    public var onState: ((DictationState) -> Void)?
    public var onError: ((String) -> Void)?
    /// The real error behind each `onError` call, for the log: the pill gets a sentence in the user's language, the
    /// log keeps what actually failed.
    public var onErrorDetail: ((Error) -> Void)?
    /// Where the words of `onError` come from: the bundle in the app, the shipped strings in tests.
    public var localize: (L10nKey) -> String = { $0.text }
    /// A press while the previous dictation is still transcribing: ignored.
    public var onBusy: (() -> Void)?
    /// Once per transcribed dictation (not for a tap or a cancelled one): its
    /// timing, with no text, for the log.
    public var onTiming: ((DictationTiming) -> Void)?
    /// Length of the recording being transcribed (or last transcribed).
    public private(set) var recordingSeconds: Double = 0
    /// What a failed transcription gets before the error is reported: the
    /// recording is still held, so a daemon that is merely restarting is
    /// polled for an answer and the held audio uploaded once more. nil
    /// reports the failure at once.
    public var daemonRetry: DaemonRetry?
    /// The retry's start and its one terminal event, for the log: no text.
    public var onRetry: ((DaemonRetryEvent) -> Void)?
    /// Every delivered dictation, pasted or left on the clipboard: what a paste
    /// that went nowhere cannot lose.
    public let history = DictationHistory()

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let output: TextOutput
    private let sampleRate = 16000.0
    /// Bumped by `cancel`: a transcription started under an older generation
    /// neither pastes nor touches the state when it finishes.
    private var generation = 0
    /// The current dictation's chunk route from the recorder to the transcriber.
    private var route: FeedRoute?

    public convenience init(recorder: Recorder, output: TextOutput, mode: HotkeyMode = .hold,
                            transcribe: @escaping ([Float]) async throws -> String) {
        self.init(recorder: recorder, output: output, mode: mode, transcriber: OneShotTranscriber(transcribe))
    }

    public init(recorder: Recorder, output: TextOutput, mode: HotkeyMode = .hold,
                transcriber: Transcriber) {
        self.recorder = recorder
        self.output = output
        self.mode = mode
        self.transcriber = transcriber
    }

    public func keyDown() {
        switch (mode, state) {
        case (_, .idle):
            do {
                try recorder.prepare()
            } catch {
                onErrorDetail?(error)
                onError?(String(format: localize(.noticeRecordFailed), error.localizedDescription))
                return
            }
            // Route chunks before the microphone runs, so the first chunk has
            // somewhere to go: a chunk recorded but never fed would make the
            // session's audio differ from the recording that `finish(all:)`
            // reconciles against.
            transcriber.begin()
            openRoute()
            state = .recording
            do {
                try recorder.start()
            } catch {
                closeRoute()
                transcriber.cancel()
                state = .idle
                onErrorDetail?(error)
                onError?(String(format: localize(.noticeRecordFailed), error.localizedDescription))
            }
        case (.toggle, .recording):
            finish()
        case (_, .transcribing):
            onBusy?()
        default:
            // Key repeat while holding: ignore.
            break
        }
    }

    /// Ends the recording as if the key had been released: the recorder hit its
    /// length cap, or the microphone went away.
    public func finishRecording() {
        if state == .recording {
            finish()
        }
    }

    public func keyUp() {
        if mode == .hold && state == .recording {
            finish()
        }
    }

    /// Drops the recording, or the result of a transcription in flight, so
    /// nothing is pasted. The daemon may still finish the request; its text is
    /// thrown away.
    public func cancel() {
        switch state {
        case .idle:
            return
        case .recording:
            _ = recorder.stop()
            closeRoute()
            transcriber.cancel()
        case .transcribing:
            transcriber.cancel()
        }
        generation += 1
        state = .idle
    }

    private func openRoute() {
        let route = FeedRoute(transcriber: transcriber)
        self.route = route
        recorder.onSamples = route.sink
    }

    /// What the route had not fed yet is the tail of the recording, which
    /// `finish(all:)` appends itself.
    private func closeRoute() {
        recorder.onSamples = nil
        route?.close()
        route = nil
    }

    private func finish() {
        // The release: taken before the recorder stops, so stopping the audio
        // engine counts toward the latency the user feels.
        let released = DispatchTime.now().uptimeNanoseconds
        let samples = recorder.stop()
        closeRoute()
        recordingSeconds = Double(samples.count) / sampleRate
        guard recordingSeconds >= minSeconds else {
            // A tap, not speech: the session it opened must still be closed.
            transcriber.cancel()
            state = .idle
            return
        }
        state = .transcribing
        let started = generation
        let seconds = recordingSeconds
        Task { @MainActor in
            var result: Result<String, Error>
            do {
                result = .success(try await transcriber.finish(all: samples))
            } catch {
                result = .failure(error)
            }
            // A dead daemon can be mid-restart while the recording is still in
            // `samples`: wait for it to answer, then upload the held audio once
            // more. A cancelled or superseded dictation gets neither the wait
            // nor the retry, and only an unreachable daemon is worth it.
            var retried = false
            var waitedMs = 0
            if case .failure(let error) = result, DaemonRetry.worthWaiting(for: error),
               let retry = daemonRetry, started == generation {
                retried = true
                onRetry?(.started)
                let waitStart = retry.now()
                let answered = await retry.wait(live: { self.generation == started })
                waitedMs = Int((retry.now() - waitStart) * 1000)
                if answered, started == generation {
                    do {
                        result = .success(try await transcriber.finish(all: samples))
                    } catch {
                        result = .failure(error)
                    }
                }
            }
            guard started == generation else {
                if retried { onRetry?(.cancelled(waitedMs: waitedMs)) }
                return
            }
            if retried {
                if case .success = result { onRetry?(.recovered(waitedMs: waitedMs)) } else { onRetry?(.gaveUp(waitedMs: waitedMs)) }
            }
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - released) / 1_000_000)
            let outcome: DictationTiming.Outcome
            var delivery: Delivery?
            switch result {
            case .success(let text) where !text.isEmpty:
                delivery = output.deliver(text)
                // Whatever became of the paste, the text is kept.
                history.add(text)
                outcome = .delivered
            case .success:
                outcome = .empty
            case .failure(let error):
                onErrorDetail?(error)
                onError?(TranscriptionError.plain(error, text: localize))
                outcome = .failed
            }
            onTiming?(DictationTiming(recordedSeconds: seconds, releaseToTextMs: elapsedMs,
                                      stats: transcriber.finishStats, outcome: outcome, delivery: delivery,
                                      retried: retried, waitedMs: waitedMs))
            state = .idle
        }
    }
}
