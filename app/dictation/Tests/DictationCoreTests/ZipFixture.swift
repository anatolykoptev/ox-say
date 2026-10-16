import Foundation

/// A zip archive of stored (uncompressed) entries, enough for the importers to
/// open a .docx or .odt the tests describe by hand.
enum ZipFixture {
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let versionNeeded: UInt16 = 20
    private static let crcPolynomial: UInt32 = 0xEDB8_8320
    private static let bitsPerByte = 8

    static func archive(_ entries: [(name: String, content: String)]) -> Data {
        var body = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let content = Data(entry.content.utf8)
            let crc = crc32(content)
            let offset = UInt32(body.count)
            body.append(contentsOf: header(localHeaderSignature, crc, content.count, name.count, central: false))
            body.append(name)
            body.append(content)
            directory.append(contentsOf: header(centralHeaderSignature, crc, content.count, name.count, central: true))
            directory.append(contentsOf: le32(offset))
            directory.append(name)
        }
        var out = body
        out.append(directory)
        out.append(contentsOf: le32(endSignature) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
                   + le32(UInt32(directory.count)) + le32(UInt32(body.count)) + le16(0))
        return out
    }

    /// The fixed part of a local or central header; the central one has the extra
    /// fields (comment length, disk, attributes) before the entry's offset.
    private static func header(_ signature: UInt32, _ crc: UInt32, _ size: Int, _ nameLength: Int, central: Bool) -> [UInt8] {
        var out = le32(signature)
        if central { out += le16(versionNeeded) }
        out += le16(versionNeeded) + le16(0) + le16(0) + le16(0) + le16(0)
        out += le32(crc) + le32(UInt32(size)) + le32(UInt32(size)) + le16(UInt16(nameLength)) + le16(0)
        if central { out += le16(0) + le16(0) + le16(0) + le32(0) }
        return out
    }

    private static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<bitsPerByte { crc = crc & 1 == 1 ? (crc >> 1) ^ crcPolynomial : crc >> 1 }
        }
        return ~crc
    }
}
