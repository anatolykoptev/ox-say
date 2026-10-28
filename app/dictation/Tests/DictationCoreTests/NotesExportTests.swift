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

    private let sample = MeetingInfo(id: "a", title: "Plan", started: Date(timeIntervalSince1970: 1_792_765_800), status: .done,
                                     notesMD: "# notes", transcriptMD: "# transcript")

    /// exFAT (and some network shares) refuse RENAME_EXCL with ENOTSUP: the
    /// export must still land, and a second meeting must still get " 2".
    /// Mutation: NotesExport.claim, change `guard code == ENOTSUP || code == EINVAL`
    /// to `guard false` (no fallback) -> RED (write throws, nothing is exported).
    func testAVolumeWithoutExclusiveRenameFallsBackToACheckedMove() throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls = 0
        let refuse: NotesExport.ExclusiveRename = { _, _ in calls += 1; return ENOTSUP }
        let first = try NotesExport.write(info: sample, in: folder, fm: .default, timeZone: utc, exclusiveRename: refuse)
        let second = try NotesExport.write(info: sample, in: folder, fm: .default, timeZone: utc, exclusiveRename: refuse)
        XCTAssertGreaterThan(calls, 0, "the volume's refusal was actually exercised")
        XCTAssertEqual(first.lastPathComponent, "2026-10-23 14.30 Plan")
        XCTAssertEqual(second.lastPathComponent, "2026-10-23 14.30 Plan 2")
        for dir in [first, second] {
            let notes = try String(contentsOf: dir.appendingPathComponent("notes.md"))
            let transcript = try String(contentsOf: dir.appendingPathComponent("transcript.md"))
            XCTAssertEqual(notes, "# notes")
            XCTAssertEqual(transcript, "# transcript")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left.count, 2, "no staging directory is left: \(left)")
    }

    /// EINVAL is the other way a volume says it has no exclusive rename.
    func testEinvalAlsoFallsBack() throws {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try NotesExport.write(info: sample, in: folder, fm: .default, timeZone: utc, exclusiveRename: { _, _ in EINVAL })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("notes.md").path))
    }

    /// Any other errno is a real failure and is not hidden behind the fallback.
    func testOtherRenameErrorsStillThrow() {
        let folder = tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try NotesExport.write(info: sample, in: folder, fm: .default, timeZone: utc, exclusiveRename: { _, _ in EACCES })
            XCTFail("want an error")
        } catch {
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"], [])
    }

    /// A crash leaves `.ox-say-export-*` holding private notes; a synced folder
    /// would upload it. Old ones go, a fresh one (maybe a concurrent export) stays.
    /// Mutation: NotesExport.sweepStaleStaging, delete the `try? fm.removeItem(at: url)` -> RED.
    func testStaleStagingDirectoriesAreSweptAndFreshOnesKept() throws {
        let fm = FileManager.default
        let folder = tempDir()
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent(".ox-say-export-OLD")
        let fresh = folder.appendingPathComponent(".ox-say-export-FRESH")
        let other = folder.appendingPathComponent(".not-ours")
        for d in [old, fresh, other] { try fm.createDirectory(at: d, withIntermediateDirectories: false) }
        try "secret".write(to: old.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 60)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 60)], ofItemAtPath: other.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: fresh.path)
        let out = try NotesExport.write(info: sample, in: folder, timeZone: utc)
        XCTAssertFalse(fm.fileExists(atPath: old.path), "a 20-minute-old staging directory is removed")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a 1-minute-old one may be a live export")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "only our own prefix is touched")
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("notes.md").path))
    }

    // MARK: the failure sentence (localized)

    /// The export notice goes through the keys, so a Russian user reads Russian.
    /// Mutation: NotesExport.explain, `case ENOSPC: return text(.noticeExportDiskFull)` -> `.noticeExportOther` -> RED.
    func testAnExportFailureIsSaidThroughTheKeys() {
        let key: (L10nKey) -> String = { $0.rawValue }
        func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        XCTAssertEqual(NotesExport.explain(posix(ENOSPC), text: key), "notice.export.disk_full")
        XCTAssertEqual(NotesExport.explain(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), text: key), "notice.export.disk_full")
        for code in [EACCES, EPERM, EROFS] { XCTAssertEqual(NotesExport.explain(posix(code), text: key), "notice.export.read_only") }
        XCTAssertEqual(NotesExport.explain(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError), text: key), "notice.export.read_only")
        for code in [ENOENT, ENOTDIR, ENODEV] { XCTAssertEqual(NotesExport.explain(posix(code), text: key), "notice.export.folder_missing") }
        XCTAssertEqual(NotesExport.explain(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError), text: key), "notice.export.folder_missing")
        XCTAssertEqual(NotesExport.explain(posix(EIO), text: key), "notice.export.other")
    }

    func testTheExportSentencesExistInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (locale, needle) in [("en", "the disk is full"), ("ru", "на диске нет места")] {
            let text = try String(contentsOf: root.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings"), encoding: .utf8)
            XCTAssertTrue(text.contains("\"notice.export.disk_full\" = \"\(needle)\""), locale)
            for k in ["folder_missing", "read_only", "other"] { XCTAssertTrue(text.contains("\"notice.export.\(k)\" = \""), "\(locale) \(k)") }
        }
    }
}

/// A disk that takes notes.md and refuses transcript.md.
private final class TranscriptRefusingFileManager: FileManager {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.hasSuffix("transcript.md") { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}
