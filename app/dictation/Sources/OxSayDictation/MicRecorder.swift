import AVFoundation
import DictationCore

enum RecorderError: LocalizedError {
    case noInput
    case notAllowed
    case askedForPermission

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available."
        case .notAllowed: return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .askedForPermission: return "Allow microphone access, then try again."
        }
    }
}

/// Records the default input device as 16 kHz mono float samples, which is what
/// the daemon's speech-to-text wants.
final class MicRecorder: Recorder {
    /// A stuck key must not record forever.
    var maxSeconds: Double = 120
    /// Loudness per frequency band, 0...1, for each chunk of audio. Called on the
    /// audio thread.
    var onLevels: (([Float]) -> Void)?
    /// Every converted 16 kHz mono chunk, in order, on the audio thread: the
    /// streaming transcription session is fed from it. The recorder still keeps
    /// the full recording itself, for the finish and for the fallback upload.
    /// Rebound per dictation on the main thread, so access goes through `lock`.
    var onSamples: (([Float]) -> Void)? {
        get { lock.withLock { _onSamples } }
        set { lock.withLock { _onSamples = newValue } }
    }
    private var _onSamples: (([Float]) -> Void)?
    /// The recording reached `maxSeconds` or lost its input device (AirPods
    /// connecting, a new default input): it has stopped growing and should be
    /// finished. Called on the main thread with the reason.
    var onEnded: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    /// Bumped per start/stop under `lock`; the tap closure captures it, so a
    /// buffer still in flight across a recording boundary is dropped instead
    /// of leaking the old recording's tail into the next one.
    private var epoch = 0
    private var ended = false
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private let meter = LevelMeter(bands: 9, sampleRate: 16000)

    func start() throws {
        // Without permission the engine still runs and records silence, which
        // would look like dictation that heard nothing. Say what is wrong instead.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw RecorderError.askedForPermission
        default:
            throw RecorderError.notAllowed
        }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        epoch += 1
        let tapEpoch = epoch
        lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        lock.lock()
        ended = false
        lock.unlock()
        guard let converter = AVAudioConverter(from: format, to: target) else { throw RecorderError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, converter, epoch: tapEpoch)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        // The engine stops itself when the input device changes; without this the
        // recording would go quiet and look like the user stopped talking.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.end("The microphone changed while recording.")
        }
    }

    func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        epoch += 1
        defer { lock.unlock() }
        return samples
    }

    private func end(_ reason: String) {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        if first { onEnded?(reason) }
    }

    private func append(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, epoch tapEpoch: Int) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        onLevels?(meter.levels(chunk))
        // The sink is captured with the epoch check under the one lock: a chunk
        // emitted can only land on the stream of the recording it belongs to.
        let (full, sink) = lock.withLock { () -> (Bool, (([Float]) -> Void)?) in
            guard epoch == tapEpoch else { return (false, nil) }
            let full = Double(samples.count) / target.sampleRate >= maxSeconds
            if !full { samples.append(contentsOf: chunk) }
            return (full, full ? nil : _onSamples)
        }
        sink?(chunk)
        if full {
            DispatchQueue.main.async { [weak self] in
                self?.end("Recordings stop after \(Int(self?.maxSeconds ?? 0)) seconds.")
            }
        }
    }
}
