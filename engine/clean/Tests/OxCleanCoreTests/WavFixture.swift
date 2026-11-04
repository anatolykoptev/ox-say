import Foundation

/// Hand-built RIFF files, so a test can make exactly the malformed shape it wants (the writer under test would only
/// ever produce well-formed ones).
enum WavFixture {
    static func u16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
    static func u32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    static func floats(_ xs: [Float]) -> [UInt8] { xs.flatMap { u32($0.bitPattern) } }
    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// One chunk: id, the size field as GIVEN (it may lie), the payload, and the pad byte an odd payload needs.
    static func chunk(_ id: String, size: UInt32? = nil, _ payload: [UInt8], pad: Bool = true) -> [UInt8] {
        ascii(id) + u32(size ?? UInt32(payload.count)) + payload + (pad && payload.count % 2 == 1 ? [0] : [])
    }

    /// `fmt ` payload of the plain 16-byte shape.
    static func fmt(tag: Int = 3, channels: Int = 1, rate: Int = 48000, bits: Int = 32) -> [UInt8] {
        let align = channels * bits / 8
        return u16(tag) + u16(channels) + u32(UInt32(rate)) + u32(UInt32(rate * align)) + u16(align) + u16(bits)
    }

    static let guidIEEEFloat: [UInt8] = [3, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
    static let guidPCM: [UInt8] = [1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]

    /// `fmt ` payload of WAVE_FORMAT_EXTENSIBLE (40 bytes) carrying `guid`.
    static func fmtExtensible(guid: [UInt8], channels: Int = 1, rate: Int = 48000, bits: Int = 32) -> [UInt8] {
        let align = channels * bits / 8
        return u16(0xFFFE) + u16(channels) + u32(UInt32(rate)) + u32(UInt32(rate * align)) + u16(align) + u16(bits)
            + u16(22) + u16(bits) + u32(channels == 1 ? 4 : 3) + guid
    }

    static func riff(_ chunks: [[UInt8]]) -> [UInt8] {
        let body = ascii("WAVE") + chunks.flatMap { $0 }
        return ascii("RIFF") + u32(UInt32(body.count)) + body
    }

    static func tmp(_ name: String = "wav") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oxclean-\(name)-\(UUID()).wav")
    }

    static func write(bytes: [UInt8]) throws -> URL {
        let url = tmp()
        try Data(bytes).write(to: url)
        return url
    }

    /// A minimal well-formed float WAV.
    static func write(rate: Int, channels: Int, samples: [Float]) throws -> URL {
        try write(bytes: riff([chunk("fmt ", fmt(channels: channels, rate: rate)), chunk("data", floats(samples))]))
    }
}
