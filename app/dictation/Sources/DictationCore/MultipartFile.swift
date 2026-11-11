import Foundation

/// A multipart/form-data body written to a file, so a long recording is streamed from disk to disk and uploaded with
/// `URLSession.upload(for:fromFile:)`; it is never held in memory whole.
public enum MultipartFile {
    /// One read of the recording at a time.
    static let chunk = 1 << 20

    /// Writes the fields (in name order, so the body is the same every time) and then `file` as the part named `file`,
    /// closed by the `--boundary--` trailer. A failure leaves no half-written body behind.
    public static func write(file: URL, fields: [String: String], boundary: String, to out: URL) throws {
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
                try writer.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(header(name))\"\r\n\r\n\(value)\r\n".utf8))
            }
            try writer.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(header(file.lastPathComponent))\"\r\n"
                                              + "Content-Type: application/octet-stream\r\n\r\n").utf8))
            while let piece = try reader.read(upToCount: chunk), !piece.isEmpty {
                try writer.write(contentsOf: piece)
            }
            try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// A value that sits inside a quoted header parameter: a quote or a line break would end it early.
    private static func header(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
