import Foundation

/// The samples of the recording in progress, and the gate that keeps a tap
/// buffer still in flight across a recording boundary out of the next
/// recording. `start`/`stop` and `onSamples` come from the main thread,
/// `append` from the audio thread.
public final class RecordingBuffer: @unchecked Sendable {
    public enum Appended: Equatable {
        /// The chunk belongs to a recording that already stopped: dropped.
        case stale
        /// Stored, and handed to `onSamples`.
        case stored
        /// The recording is at `maxSeconds`: dropped, and the recording should end.
        case full
    }

    private let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Float] = []
    private var epoch = 0
    private var _maxSeconds: Double
    private var _onSamples: (([Float]) -> Void)?

    public init(sampleRate: Double = 16000, maxSeconds: Double = 120) {
        self.sampleRate = sampleRate
        _maxSeconds = maxSeconds
    }

    public var maxSeconds: Double {
        get { lock.withLock { _maxSeconds } }
        set { lock.withLock { _maxSeconds = newValue } }
    }

    /// Every stored chunk, in order, called on the audio thread outside the lock.
    public var onSamples: (([Float]) -> Void)? {
        get { lock.withLock { _onSamples } }
        set { lock.withLock { _onSamples = newValue } }
    }

    /// Starts a recording: clears the samples and returns the epoch its tap
    /// must present with every chunk.
    public func start() -> Int {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            epoch += 1
            return epoch
        }
    }

    /// Stops the recording and returns its samples; a chunk of its tap that
    /// arrives later is stale.
    public func stop() -> [Float] {
        lock.withLock {
            epoch += 1
            return samples
        }
    }

    /// Stores a chunk recorded under `epoch` and hands it to `onSamples`. The
    /// epoch check, the store and the choice of sink are one step under the
    /// lock, so a chunk lands in the recording it was recorded for or nowhere.
    public func append(_ chunk: [Float], epoch tapEpoch: Int) -> Appended {
        let (result, sink) = lock.withLock { () -> (Appended, (([Float]) -> Void)?) in
            guard epoch == tapEpoch else { return (.stale, nil) }
            guard Double(samples.count) / sampleRate < _maxSeconds else { return (.full, nil) }
            samples.append(contentsOf: chunk)
            return (.stored, _onSamples)
        }
        sink?(chunk)
        return result
    }
}
