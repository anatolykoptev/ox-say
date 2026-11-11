import Foundation

/// A multipart/form-data body written to a file, so a long recording is streamed from disk to disk and uploaded with
/// `URLSession.upload(for:fromFile:)`; it is never held in memory whole.
public enum MultipartFile {
    public enum Failure: Error, Equatable {
        /// A field value holds a line break (or the boundary): it would be read as part of the body's structure.
        case invalidField(String)
        /// The file is longer than `maxFileBytes` — it grew after it was checked, or was never checked.
        case tooLarge
    }

    /// One read of the recording at a time.
    static let chunk = 1 << 20

    /// Writes the fields (in name order, so the body is the same every time) and then `file` as the part named `file`,
    /// closed by the `--boundary--` trailer. A field value with a CR or LF (or the boundary) is refused before any byte is
    /// written; a file that passes `maxFileBytes` while it is copied stops the copy. A failure leaves no body behind.
    public static func write(file: URL, fields: [String: String], boundary: String, to out: URL,
                             maxFileBytes: Int64? = nil) throws {
        for (name, value) in fields where value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) || value.contains("--\(boundary)") {
            throw Failure.invalidField(name)
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let writer = try FileHandle(forWritingTo: out)
            defer { try? writer.close() }
            for name in fields.keys.sorted() {
                let value = fields[name] ?? ""
                try writer.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try writer.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; \(fileParameters(file.lastPathComponent))\r\n"
                                              + "Content-Type: application/octet-stream\r\n\r\n").utf8))
            var copied: Int64 = 0
            while let piece = try reader.read(upToCount: chunk), !piece.isEmpty {
                copied += Int64(piece.count)
                if let maxFileBytes, copied > maxFileBytes { throw Failure.tooLarge }
                try writer.write(contentsOf: piece)
            }
            try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// `name="file"; filename="<ascii fallback>"; filename*=UTF-8''<percent-encoded>` (RFC 6266, RFC 5987): the fallback holds
    /// only printable ASCII without a quote or backslash, the real name travels percent-encoded, so nothing in a file name
    /// can end the quoted parameter or the header line.
    static func fileParameters(_ name: String) -> String {
        let fallback = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7f && scalar != "\"" && scalar != "\\" ? Character(scalar) : "_"
        })
        let attr = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: attr) ?? "file"
        return "name=\"file\"; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }
}
