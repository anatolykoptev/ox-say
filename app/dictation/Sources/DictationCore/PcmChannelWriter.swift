import Foundation

/// Appends one channel of a meeting to its file as raw signed 16-bit
/// little-endian mono at 16 kHz — the format the daemon reads (internal/meeting
/// audio.go). There is no header to repair and no segment to close: whatever
/// reached the file when the app died is the recording.
///
/// Both channels start at the same instant `t0`; a channel whose device starts
/// late, loses its input for a while (a tap rebuilt after the output device
/// changed) or drops buffers is padded with silence, so a sample's position in
/// the file is its time in the meeting, and a word's timestamp in one channel
/// means the same as in the other.
public final class PcmChannelWriter {
    public static let sampleRate = 16000
    /// A gap shorter than this is clock jitter, not lost audio.
    public static let gapTolerance = 1600 // 100 ms

    private let handle: FileHandle
    private let t0: UInt64
    private var written = 0
    private let lock = NSLock()
    /// Writes that failed; the controller stops and tells the user when this grows.
    public private(set) var failedWrites = 0

    /// `t0` is the meeting's start, in the same nanosecond clock `append` is given.
    public init(url: URL, t0: UInt64) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        self.t0 = t0
    }

    /// Samples written so far, padding included: the channel's length.
    public var samples: Int { lock.withLock { written } }

    /// Appends `chunk`, recorded at `nanos` (the time of its first sample).
    public func append(_ chunk: [Float], atNanos nanos: UInt64) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let elapsed = nanos > t0 ? Double(nanos - t0) / 1e9 : 0
        let expected = Int(elapsed * Double(Self.sampleRate))
        if expected - written > Self.gapTolerance { pad(to: expected) }
        let data = Self.pcm16(chunk)
        written += chunk.count
        write(data)
    }

    /// Zeros up to `target` samples, a second at a time: a Mac that slept for
    /// hours must not allocate the whole gap at once.
    private func pad(to target: Int) {
        let second = Data(count: Self.sampleRate * 2)
        while written < target {
            let n = min(Self.sampleRate, target - written)
            write(n == Self.sampleRate ? second : Data(count: n * 2))
            written += n
        }
    }

    /// A failed write (a full disk) is counted, not thrown from the audio thread:
    /// `failedWrites` > 0 tells the controller the recording is incomplete.
    private func write(_ data: Data) {
        do { try handle.write(contentsOf: data) } catch { failedWrites += 1 }
    }

    /// Pads the channel with silence up to `nanos`, so both channels end together.
    public func finish(atNanos nanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let expected = nanos > t0 ? Int(Double(nanos - t0) / 1e9 * Double(Self.sampleRate)) : 0
        pad(to: expected)
        try? handle.close()
    }

    static func pcm16(_ chunk: [Float]) -> Data {
        var out = Data(count: chunk.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, f) in chunk.enumerated() {
                p[i] = Int16(littleEndian: Int16(max(-1, min(1, f)) * 32767))
            }
        }
        return out
    }
}
