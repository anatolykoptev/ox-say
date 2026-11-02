import FluidAudio
import Foundation

/// 16 kHz mono s16le PCM read straight from the mapped file: no float copy of the recording and no temporary file
/// (`readPCM16`'s reason, PCM.swift:5-9). Reading past the end copies what exists, like FluidAudio's array source.
public struct MappedPCM16Source: AudioSampleSource {
    private let data: Data
    public init(contentsOf url: URL) throws {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { throw PCMError.unreadable }
        guard d.count >= 2 else { throw PCMError.empty }
        data = d
    }
    public var sampleCount: Int { data.count / 2 }
    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0 else { return }
        let start = max(0, offset)
        guard start < sampleCount else { return }
        let n = min(count, sampleCount - start)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                destination[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (start + i) * 2, as: Int16.self))) / 32768
            }
        }
    }
}

public enum ChunkFeeder {
    /// Hands the whole source to `sink` in chunks of `chunkSamples` (the last one may be shorter).
    public static func feed(source: AudioSampleSource, chunkSamples: Int, _ sink: ([Float]) throws -> Void) throws {
        var buf = [Float](repeating: 0, count: chunkSamples)
        var offset = 0
        while offset < source.sampleCount {
            let n = min(chunkSamples, source.sampleCount - offset)
            try buf.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: offset, count: n) }
            try sink(Array(buf[0..<n]))
            offset += n
        }
    }
}
