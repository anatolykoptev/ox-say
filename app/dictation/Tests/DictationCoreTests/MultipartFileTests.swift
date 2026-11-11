import XCTest
@testable import DictationCore

final class MultipartFileTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMultipartKeepsTheFileBytesAndTheFields() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir.appendingPathComponent("a.wav")); try? FileManager.default.removeItem(at: dir.appendingPathComponent("body")); try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.wav"); try Data([0, 1, 2, 255]).write(to: src)
        let out = dir.appendingPathComponent("body")
        try MultipartFile.write(file: src, fields: ["title": "Проба", "model": "parakeet"], boundary: "B", to: out)
        let body = try Data(contentsOf: out)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"title\"\r\n\r\nПроба\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"a.wav\""))
        XCTAssertNotNil(body.range(of: Data([0, 1, 2, 255])))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    /// A file larger than one copy chunk comes through whole and in order (the body is streamed, not loaded).
    func testALargeFileIsStreamedWhole() throws {
        let dir = try scratch()
        let src = dir.appendingPathComponent("big.wav"), out = dir.appendingPathComponent("body")
        defer { for u in [src, out] { try? FileManager.default.removeItem(at: u) }; try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0..<(3 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: src)
        try MultipartFile.write(file: src, fields: [:], boundary: "B", to: out)
        let body = try Data(contentsOf: out)
        let range = try XCTUnwrap(body.range(of: payload))
        XCTAssertEqual(body[range.upperBound...], Data("\r\n--B--\r\n".utf8))
    }

    /// A quote or line break in a file name must not end the header early.
    func testAHostileFileNameStaysInsideItsHeader() throws {
        let dir = try scratch()
        let src = dir.appendingPathComponent("a\"b\r\nc.wav"), out = dir.appendingPathComponent("body")
        defer { for u in [src, out] { try? FileManager.default.removeItem(at: u) }; try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: src)
        try MultipartFile.write(file: src, fields: [:], boundary: "B", to: out)
        let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        let header = try XCTUnwrap(text.components(separatedBy: "\r\n\r\n").first)
        XCTAssertEqual(header.components(separatedBy: "\r\n").count, 3, "boundary, disposition, type: nothing injected")
    }

    func testAMissingFileThrowsAndLeavesNoBody() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("body")
        do {
            try MultipartFile.write(file: dir.appendingPathComponent("nope.wav"), fields: [:], boundary: "B", to: out)
            XCTFail("a missing file must throw")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no half-written body")
    }
}
