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
    /// Mutation: NotesExport.write, delete the `while fm.fileExists` loop -> RED
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
}
