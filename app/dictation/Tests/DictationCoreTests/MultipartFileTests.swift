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

    /// A field value with a line break would let a title carry its own headers or parts: it is refused before a byte is staged.
    /// Mutation: MultipartFile.swift, the `invalidField` guard at the top of `write` removed -> RED.
    func testAFieldWithALineBreakIsRefusedBeforeAnyByteIsStaged() throws {
        let dir = try scratch()
        let src = dir.appendingPathComponent("a.wav"), out = dir.appendingPathComponent("body")
        defer { for u in [src, out] { try? FileManager.default.removeItem(at: u) }; try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: src)
        let fakeHeader = "x\r\nContent-Disposition: form-data; name=\"file\"; filename=\"evil.wav\""
        for (name, value) in [("title", fakeHeader), ("prompt", "line one\nline two"), ("language", "ru\r"), ("title", "has --B in it")] {
            do {
                try MultipartFile.write(file: src, fields: [name: value], boundary: "B", to: out)
                XCTFail("\(name) = \(value.debugDescription) must be refused")
            } catch let error as MultipartFile.Failure {
                XCTAssertEqual(error, .invalidField(name))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "nothing is staged for a refused field")
        }
    }

    /// A file name with a quote, CR/LF and Cyrillic stays inside its header: ASCII fallback plus the percent-encoded RFC 5987 form.
    /// Mutation: MultipartFile.fileParameters, send `name` raw in `filename="..."` -> RED.
    func testAHostileOrNonAsciiFileNameTravelsAsFallbackPlusPercentEncoding() throws {
        let dir = try scratch()
        let src = dir.appendingPathComponent("Инт\"ервью\r\n.m4a"), out = dir.appendingPathComponent("body")
        defer { for u in [src, out] { try? FileManager.default.removeItem(at: u) }; try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: src)
        try MultipartFile.write(file: src, fields: [:], boundary: "B", to: out)
        let body = try Data(contentsOf: out)
        let split = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8)))
        let header = body[..<split.lowerBound]
        XCTAssertTrue(header.allSatisfy { $0 < 0x80 }, "the header holds no raw non-ASCII byte")
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3, "boundary, disposition, type: nothing injected")
        XCTAssertTrue(lines[1].contains("; filename=\"___________.m4a\"; "), "ASCII fallback: \(lines[1])")
        XCTAssertTrue(lines[1].hasSuffix("filename*=UTF-8''%D0%98%D0%BD%D1%82%22%D0%B5%D1%80%D0%B2%D1%8C%D1%8E%0D%0A.m4a"), lines[1])
    }

    /// The cap is enforced while the file is copied: a file that grew past it after the size check stops the copy and leaves no body.
    /// Mutation: MultipartFile.swift, `if let maxFileBytes, copied > maxFileBytes { throw Failure.tooLarge }` removed -> RED.
    func testAFileThatPassesTheCapWhileItIsCopiedStopsTheCopy() throws {
        let dir = try scratch()
        let src = dir.appendingPathComponent("big.wav"), out = dir.appendingPathComponent("body")
        defer { for u in [src, out] { try? FileManager.default.removeItem(at: u) }; try? FileManager.default.removeItem(at: dir) }
        try Data(count: 3 * 1024 * 1024).write(to: src)
        do {
            try MultipartFile.write(file: src, fields: [:], boundary: "B", to: out, maxFileBytes: 1024 * 1024)
            XCTFail("a file past the cap must stop the copy")
        } catch let error as MultipartFile.Failure {
            XCTAssertEqual(error, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the staged body is removed")
        try MultipartFile.write(file: src, fields: [:], boundary: "B", to: out, maxFileBytes: 3 * 1024 * 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "exactly the cap passes")
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
