import Foundation
import XCTest
@testable import DictationCore

final class NotesExportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testFolderNameIsLocalTimeAndASafeTitle() {
        let t = Date(timeIntervalSince1970: 1_792_765_800) // 2026-10-23 14:30 UTC
        XCTAssertEqual(NotesExport.folderName(title: "Zoom call", started: t, timeZone: utc), "2026-10-23 14.30 Zoom call")
        XCTAssertEqual(NotesExport.folderName(title: "a/b: c\\d", started: t, timeZone: utc), "2026-10-23 14.30 a b c d")
        XCTAssertEqual(NotesExport.folderName(title: "", started: t, timeZone: utc), "2026-10-23 14.30")
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-export-\(UUID().uuidString)")
    }

    /// Two meetings in one minute never overwrite each other.
    /// Mutation: NotesExport.claim, change `guard code == EEXIST` to `guard false` -> RED
    /// (createDirectory throws on the second meeting and its notes are lost).
    func testWritesBothFilesAndNeverOverwritesAnEarlierMeeting() throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_792_765_800), status: .done,
                               notesMD: "# notes", transcriptMD: "# transcript")
        let first = try NotesExport.write(info: info, in: folder, timeZone: utc)
        let second = try NotesExport.write(info: info, in: folder, timeZone: utc)
        XCTAssertNotEqual(first, second)
        let notes = try String(contentsOf: first.appendingPathComponent("notes.md"))
        let transcript = try String(contentsOf: second.appendingPathComponent("transcript.md"))
        XCTAssertEqual(notes, "# notes")
        XCTAssertEqual(transcript, "# transcript")
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2"))
    }

    func testNothingToWriteIsAnError() {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try NotesExport.write(info: MeetingInfo(id: "a", status: .done), in: folder)
            XCTFail("want an error")
        } catch {
            XCTAssertEqual(error as? NotesExport.ExportError, .nothingToWrite)
        }
    }

    /// A name that was too long for APFS (255 bytes) failed with ENAMETOOLONG
    /// and the notes copy was never written.
    /// Mutation: NotesExport.folderName, change `budget < 0` to `false` (no byte cap) -> RED.
    func testACjkTitleFitsTheFilesystemNameLimit() throws {
        let t = Date(timeIntervalSince1970: 1_792_765_800)
        let title = String(repeating: "会", count: 80) // 240 bytes
        let name = NotesExport.folderName(title: title, started: t, timeZone: utc)
        XCTAssertLessThanOrEqual(name.utf8.count, NotesExport.maxNameBytes)
        XCTAssertTrue(name.hasPrefix("2026-10-23 14.30 会"))
        XCTAssertTrue(name.hasSuffix("会"))
        // The real filesystem agrees, including the " 2" suffix of a second meeting.
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = MeetingInfo(id: "a", title: title, started: t, status: .done, notesMD: "n", transcriptMD: nil)
        let first = try NotesExport.write(info: info, in: folder, timeZone: utc)
        let second = try NotesExport.write(info: info, in: folder, timeZone: utc)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("notes.md").path))
        XCTAssertEqual(second.lastPathComponent, first.lastPathComponent + " 2")
    }

    func testAnEmojiSequenceIsCutWholeNeverInTheMiddle() {
        let t = Date(timeIntervalSince1970: 1_792_765_800)
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}" // one Character, 25 bytes
        let name = NotesExport.folderName(title: String(repeating: family, count: 40), started: t, timeZone: utc)
        XCTAssertLessThanOrEqual(name.utf8.count, NotesExport.maxNameBytes)
        let title = String(name.dropFirst("2026-10-23 14.30 ".count))
        XCTAssertFalse(title.isEmpty)
        XCTAssertEqual(title, String(repeating: family, count: title.count), "every kept emoji is whole")
        XCTAssertEqual(title.unicodeScalars.count, title.count * 7)
    }

    func testInvisibleLineAndBidiControlsAreStripped() {
        let t = Date(timeIntervalSince1970: 1_792_765_800)
        let title = "a\u{2028}b\u{2029}c\u{202E}d\u{202A}e\u{2066}f\u{2069}g"
        XCTAssertEqual(NotesExport.folderName(title: title, started: t, timeZone: utc), "2026-10-23 14.30 abcdefg")
    }

    /// A failure part-way leaves nothing in the user's folder: no half-written
    /// meeting folder and no staging directory.
    /// Mutation: NotesExport.write, drop the `try? fm.removeItem(at: staging)` in the catch -> RED.
    func testAFailedWriteLeavesNoPartialFolder() throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_792_765_800), status: .done,
                               notesMD: "# notes", transcriptMD: "# transcript")
        do {
            _ = try NotesExport.write(info: info, in: folder, fm: TranscriptRefusingFileManager(), timeZone: utc)
            XCTFail("want an error")
        } catch {}
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, [], "left behind: \(left)")
    }

    /// Three earlier meetings in the same minute: the next is " 4".
    func testTheNameCounterSkipsEveryTakenName() throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_792_765_800), status: .done,
                               notesMD: "n", transcriptMD: nil)
        for _ in 0..<3 { _ = try NotesExport.write(info: info, in: folder, timeZone: utc) }
        let fourth = try NotesExport.write(info: info, in: folder, timeZone: utc)
        XCTAssertEqual(fourth.lastPathComponent, "2026-10-23 14.30 Plan 4")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.count, 4, "no staging directory is left: \(names)")
    }
}

/// A disk that takes notes.md and refuses transcript.md.
private final class TranscriptRefusingFileManager: FileManager {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.hasSuffix("transcript.md") { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}
