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
    private let transcribe: ([Float]) async throws -> String
    private let output: TextOutput
    private let sampleRate = 16000.0
    /// Bumped by `cancel`: a transcription started under an older generation
    /// neither pastes nor touches the state when it finishes.
    private var generation = 0

    public init(recorder: Recorder, output: TextOutput, mode: HotkeyMode = .hold,
                transcribe: @escaping ([Float]) async throws -> String) {
        self.recorder = recorder
        self.output = output
        self.mode = mode
        self.transcribe = transcribe
    }

    public func keyDown() {
        switch (mode, state) {
        case (_, .idle):
            do {
                try recorder.start()
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
        case .transcribing:
            break
        }
        generation += 1
        state = .idle
    }

    private func finish() {
        let samples = recorder.stop()
        recordingSeconds = Double(samples.count) / sampleRate
        guard recordingSeconds >= minSeconds else {
            state = .idle
            return
        }
        state = .transcribing
        let started = generation
        Task { @MainActor in
            let result: Result<String, Error>
            do {
                result = .success(try await transcribe(samples))
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
