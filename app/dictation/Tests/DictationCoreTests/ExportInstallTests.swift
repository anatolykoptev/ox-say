import XCTest
@testable import DictationCore

/// «Сохранить…» of a finished voiceover: the old file survives a failed copy, and the track saved onto itself is left alone.
final class ExportInstallTests: XCTestCase {
    private func withDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ox-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    private func names(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testANewDestinationGetsTheCopyAndNoStagingRemains() throws {
        try withDir { dir in
            let source = try write(dir, "a.wav", "new")
            let target = dir.appendingPathComponent("b.wav")
            try ExportRules.install(source, to: target)
            let got = try text(target)
            XCTAssertEqual(got, "new")
            let listed = try names(dir)
            XCTAssertEqual(listed, ["a.wav", "b.wav"])
        }
    }

    func testAnExistingFileIsReplacedByTheCopy() throws {
        try withDir { dir in
            let source = try write(dir, "a.wav", "new")
            let target = try write(dir, "b.wav", "old")
            try ExportRules.install(source, to: target)
            let got = try text(target)
            XCTAssertEqual(got, "new")
        }
    }

    /// A copy that fails half way (disk full) must leave the person's earlier file as it was.
    func testAFailedCopyKeepsTheOldFileAndLeavesNoStaging() throws {
        struct DiskFull: Error {}
        try withDir { dir in
            let source = try write(dir, "a.wav", "new")
            let target = try write(dir, "b.wav", "old")
            var failed = false
            do {
                try ExportRules.install(source, to: target, copy: { _, staged in
                    try Data("par".utf8).write(to: staged)
                    throw DiskFull()
                })
            } catch is DiskFull {
                failed = true
            }
            XCTAssertTrue(failed, "the copy's own error reaches the caller")
            let got = try text(target)
            XCTAssertEqual(got, "old")
            let listed = try names(dir)
            XCTAssertEqual(listed, ["a.wav", "b.wav"], "the partial copy is taken down")
        }
    }

    /// The published WAV chosen as its own destination (also through a symlink or a hard link) is a no-op: the source survives.
    func testTheSourceAsItsOwnDestinationIsANoOpThatKeepsIt() throws {
        try withDir { dir in
            let source = try write(dir, "a.wav", "track")
            var copied = false
            try ExportRules.install(source, to: source, copy: { _, _ in copied = true })
            let link = dir.appendingPathComponent("link.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            try ExportRules.install(source, to: link, copy: { _, _ in copied = true })
            let hard = dir.appendingPathComponent("hard.wav")
            try FileManager.default.linkItem(at: source, to: hard)
            try ExportRules.install(source, to: hard, copy: { _, _ in copied = true })
            XCTAssertFalse(copied)
            let got = try text(source)
            XCTAssertEqual(got, "track")
        }
    }
}
