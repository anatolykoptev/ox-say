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
    func start() throws
    /// Stops and returns what was recorded since `start`.
    func stop() -> [Float]
}

/// Delivers dictated text to the user, e.g. by pasting it where the cursor is.
public protocol TextOutput: AnyObject {
    func deliver(_ text: String)
}

/// A transcription backend: a one-shot upload after the recording, or a
/// streaming session fed while it happens. `begin`/`cancel` come from the
/// main thread, `feed` from wherever the app pumps recorder chunks.
public protocol Transcriber: AnyObject {
    /// Prepare for a new recording (e.g. open a streaming session).
    func begin()
    /// A chunk of 16 kHz mono samples, in recording order.
    func feed(_ samples: [Float]) async
    /// The recording stopped: the text for the whole recording.
    func finish(all: [Float]) async throws -> String
    /// Drop the recording: nothing will be delivered for it.
    func cancel()
}

/// The one-shot path the app always had: `begin`/`feed`/`cancel` do nothing and
/// `finish` uploads the whole recording. Keeps the closure-based init working.
private final class OneShotTranscriber: Transcriber {
    private let transcribe: ([Float]) async throws -> String
    init(_ transcribe: @escaping ([Float]) async throws -> String) { self.transcribe = transcribe }
    func begin() {}
    func feed(_: [Float]) async {}
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
    /// A press while the previous dictation is still transcribing: ignored.
    public var onBusy: (() -> Void)?
    /// Length of the recording being transcribed (or last transcribed).
    public private(set) var recordingSeconds: Double = 0

    private let recorder: Recorder
    private let transcriber: Transcriber
    private let output: TextOutput
    private let sampleRate = 16000.0
    /// Bumped by `cancel`: a transcription started under an older generation
    /// neither pastes nor touches the state when it finishes.
    private var generation = 0

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
                try recorder.start()
                transcriber.begin()
                state = .recording
            } catch {
                onError?("Could not start recording: \(error.localizedDescription)")
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
            transcriber.cancel()
        case .transcribing:
            transcriber.cancel()
        }
        generation += 1
        state = .idle
    }

    private func finish() {
        let samples = recorder.stop()
        recordingSeconds = Double(samples.count) / sampleRate
        guard recordingSeconds >= minSeconds else {
            // A tap, not speech: the session it opened must still be closed.
            transcriber.cancel()
            state = .idle
            return
        }
        state = .transcribing
        let started = generation
        Task { @MainActor in
            let result: Result<String, Error>
            do {
                result = .success(try await transcriber.finish(all: samples))
            } catch {
                result = .failure(error)
            }
            guard started == generation else { return }
            switch result {
            case .success(let text) where !text.isEmpty:
                output.deliver(text)
            case .success:
                break
            case .failure(let error):
                onError?(String(describing: error))
            }
            state = .idle
        }
    }
}
