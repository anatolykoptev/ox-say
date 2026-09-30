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

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

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
        lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
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
        lock.lock()
        defer { lock.unlock() }
        if Double(samples.count) / target.sampleRate < maxSeconds {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        }
    }
}
