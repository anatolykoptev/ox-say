import Foundation

public enum WAV {
    /// A 16-bit PCM mono WAV file of float samples in [-1, 1]; values outside are clipped.
    public static func pcm16(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                             // PCM
        u16(1)                             // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))        // byte rate
        u16(2)                             // block align
        u16(16)                            // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples {
            let v = Int16((max(-1, min(1, s)) * 32767).rounded())
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
