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

    private let recorder: Recorder
    private let transcribe: ([Float]) async throws -> String
    private let output: TextOutput
    private let sampleRate = 16000.0

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
        default:
            // Key repeat while holding, or a press during transcription: ignore.
            break
        }
    }

    public func keyUp() {
        if mode == .hold && state == .recording {
            finish()
        }
    }

    private func finish() {
        let samples = recorder.stop()
        guard Double(samples.count) / sampleRate >= minSeconds else {
            state = .idle
            return
        }
        state = .transcribing
        Task { @MainActor in
            do {
                let text = try await transcribe(samples)
                if !text.isEmpty {
                    output.deliver(text)
                }
            } catch {
                onError?(String(describing: error))
            }
            state = .idle
        }
    }
}
