import Foundation

public enum PCMError: Error, Equatable {
    /// The file does not exist or cannot be read.
    case unreadable
    /// The file holds no sample (an odd trailing byte does not count).
    case empty
}

/// Reads 16 kHz mono signed 16-bit little-endian PCM, the format of a meeting's channel file, into floats in
/// [-1, 1). ox-diar takes the raw channel itself, not a WAV: FluidAudio's file path (`process(url)`) streams the audio
/// to a float32 temporary file in $TMPDIR that only a `defer` removes, and a killed process would leave 230 MB of
/// someone's call outside the meeting directory.
public func readPCM16(at url: URL) throws -> [Float] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw PCMError.unreadable }
    let count = data.count / 2
    guard count > 0 else { throw PCMError.empty }
    return data.withUnsafeBytes { raw in
        [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            for i in 0..<count {
                buffer[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
            initialized = count
        }
    }
}
