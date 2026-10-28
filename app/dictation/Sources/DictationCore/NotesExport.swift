import CryptoKit
import Foundation

/// Copies a finished meeting's notes and transcript into the user's notes
/// folder: one subfolder per meeting, "2026-10-23 14.30 Zoom call", holding
/// notes.md and transcript.md. The daemon keeps its own copy for Claude to
/// read; this one is for the user to find.
public enum NotesExport {
    /// APFS limits a name to 255 UTF-8 bytes. The folder name stays under this,
    /// which leaves room for a " 12" suffix and for the temp name's sibling.
    static let maxNameBytes = 200

    /// Line/paragraph separators and bidi overrides: invisible, and they let a
    /// title reorder the text around it in Finder.
    private static let invisibleControls: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = ["\u{2028}", "\u{2029}"]
        for v in 0x202A...0x202E { set.insert(Unicode.Scalar(v)!) }
        for v in 0x2066...0x2069 { set.insert(Unicode.Scalar(v)!) }
        return set
    }()

    /// A folder name for the meeting: local start time, then the title with
    /// every character a file name cannot carry replaced, cut at whole
    /// Characters so the whole name fits `maxNameBytes` UTF-8 bytes.
    public static func folderName(title: String, started: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        // Only real control characters (Cc) and the separators a name cannot hold
        // become spaces. Format characters stay: the zero-width joiner holds an
        // emoji family together, and it is a Cf, not a control.
        let bad: Set<Unicode.Scalar> = ["/", ":", "\\", "\0"]
        var spaced = String.UnicodeScalarView()
        for scalar in title.unicodeScalars where !invisibleControls.contains(scalar) {
            spaced.append(bad.contains(scalar) || scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let clean = String(spaced).split(separator: " ").joined(separator: " ")
        let base = f.string(from: started)
        var budget = maxNameBytes - base.utf8.count - 1
        var kept = ""
        for ch in clean.prefix(80) {
            budget -= ch.utf8.count
            if budget < 0 { break }
            kept.append(ch)
        }
        kept = kept.trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? base : "\(base) \(kept)"
    }

    public enum ExportError: Error, Equatable {
        case nothingToWrite
        /// `refresh` found no folder where the earlier copy was: the user moved or deleted it.
        case folderMoved
    }

    /// `refresh` moved some of the new texts into place and failed on a later one. `replaced` holds the hash of each
    /// file that IS new now (by file name), so the caller can record them as its own: the next refresh then does not
    /// take the new `notes.md` for the user's edit and can finish the rest.
    public struct PartialRefresh: Error {
        public let replaced: [String: String]
        public let underlying: Error
    }

    /// Why a copy could not be made, in the user's language and words for the status line: no Cocoa error dump, no path.
    public static func explain(_ error: Error, text: (L10nKey) -> String = { $0.text }) -> String {
        if let partial = error as? PartialRefresh { return explain(partial.underlying, text: text) }
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return text(.noticeExportDiskFull)
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return text(.noticeExportReadOnly)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return text(.noticeExportFolderMissing)
            default: break
            }
        case NSPOSIXErrorDomain:
            switch Int32(ns.code) {
            case ENOSPC: return text(.noticeExportDiskFull)
            case EACCES, EPERM, EROFS: return text(.noticeExportReadOnly)
            case ENOENT, ENOTDIR, ENODEV: return text(.noticeExportFolderMissing)
            default: break
            }
        default: break
        }
        return text(.noticeExportOther)
    }

    /// Renames `from` to `to` without replacing, returning 0 or the errno.
    typealias ExclusiveRename = (_ from: String, _ to: String) -> Int32

    static let exclusiveRename: ExclusiveRename = { from, to in
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

    /// A leftover staging directory this old is from a crash; it holds private
    /// notes and a synced folder (Dropbox, iCloud) would upload it.
    static let staleStagingAge: TimeInterval = 600
    private static let stagingPrefix = ".ox-say-export-"

    /// Writes the texts under `folder` and returns the meeting's subfolder. The
    /// files are written into a hidden sibling directory first and the
    /// directory is renamed into place, so a failed write leaves nothing half
    /// done in the user's folder. A taken name (two meetings in one minute)
    /// gets " 2", " 3"… from the rename itself failing with EEXIST, so nothing
    /// is overwritten even by a concurrent writer. A volume without exclusive
    /// rename (exFAT, some network shares) is told apart by ENOTSUP/EINVAL and
    /// uses a check-then-move instead.
    @discardableResult
    public static func write(info: MeetingInfo, in folder: URL, fm: FileManager = .default,
                             timeZone: TimeZone = .current) throws -> URL {
        try write(info: info, in: folder, fm: fm, timeZone: timeZone, exclusiveRename: exclusiveRename)
    }

    @discardableResult
    static func write(info: MeetingInfo, in folder: URL, fm: FileManager, timeZone: TimeZone,
                      exclusiveRename: ExclusiveRename) throws -> URL {
        guard info.notesMD != nil || info.transcriptMD != nil else { throw ExportError.nothingToWrite }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        sweepStaleStaging(in: folder, fm: fm)
        let name = folderName(title: info.title, started: info.started ?? Date(), timeZone: timeZone)
        let staging = folder.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            if let notes = info.notesMD { try put(notes, "notes.md", in: staging, fm: fm) }
            if let text = info.transcriptMD { try put(text, "transcript.md", in: staging, fm: fm) }
            return try claim(staging, as: name, in: folder, fm: fm, rename: exclusiveRename)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// What `refresh` did.
    public enum RefreshResult: Equatable {
        case refreshed
        /// These files were changed by the user (or cannot be shown untouched): nothing was replaced, and the caller
        /// keeps the meeting stale.
        case keptEdited([String])
    }

    /// SHA-256 (hex) of each text `write` puts in a copy, by file name: what the caller stores to recognise its own
    /// files later.
    public static func hashes(of info: MeetingInfo) -> [String: String] {
        var out: [String: String] = [:]
        if let notes = info.notesMD { out["notes.md"] = sha256(notes) }
        if let text = info.transcriptMD { out["transcript.md"] = sha256(text) }
        return out
    }

    private static func sha256(_ s: String) -> String { sha256(Data(s.utf8)) }

    private static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Writes the texts again into the subfolder an earlier `write` made, for notes that were written again after
    /// the speakers were named. `expected` is the hash of each file as it was written. A file that is there and no
    /// longer matches (or has no stored hash) is the user's, and then nothing at all is replaced: the answer names
    /// the files, so the notes are never new beside an old transcript. Otherwise both new texts are staged first
    /// and only then moved into place. A folder the user has since moved or deleted is an error (the caller then
    /// writes a new copy).
    @discardableResult
    public static func refresh(info: MeetingInfo, at dir: URL, expected: [String: String], fm: FileManager = .default,
                               stage: (Data, URL) throws -> Void = { try $0.write(to: $1) },
                               replace: ((_ original: URL, _ staged: URL) throws -> Void)? = nil) throws -> RefreshResult {
        guard info.notesMD != nil || info.transcriptMD != nil else { throw ExportError.nothingToWrite }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw ExportError.folderMoved }
        let texts = [("notes.md", info.notesMD), ("transcript.md", info.transcriptMD)].compactMap { name, text in text.map { (name, Data($0.utf8)) } }
        var edited: [String] = []
        for (name, _) in texts {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            if let have = try? Data(contentsOf: url), expected[name] == sha256(have) { continue }
            edited.append(name)
        }
        if !edited.isEmpty { return .keptEdited(edited) }
        var staged: [(temp: URL, final: URL, hash: String)] = []
        do {
            for (name, data) in texts {
                let temp = dir.appendingPathComponent("\(stagingPrefix)refresh-\(UUID().uuidString)-\(name)")
                staged.append((temp, dir.appendingPathComponent(name), sha256(data)))
                try stage(data, temp)
            }
        } catch {
            for s in staged { try? fm.removeItem(at: s.temp) }
            throw error
        }
        var replaced = 0
        do {
            for s in staged {
                if let replace { try replace(s.final, s.temp) } else { _ = try fm.replaceItemAt(s.final, withItemAt: s.temp) }
                replaced += 1
            }
        } catch {
            // A replace failed (a full disk, a revoked permission): the texts not yet moved into place leave their
            // hidden temps in the user's meeting folder. Take them down; the caller reports the failure.
            for s in staged.dropFirst(replaced) { try? fm.removeItem(at: s.temp) }
            // Texts already moved into place are new: say which, or the next refresh reads them as the user's edit.
            if replaced > 0 {
                let done = Dictionary(uniqueKeysWithValues: staged.prefix(replaced).map { ($0.final.lastPathComponent, $0.hash) })
                throw PartialRefresh(replaced: done, underlying: error)
            }
            throw error
        }
        return .refreshed
    }

    /// Removes staging directories an earlier crash left in `folder`.
    private static func sweepStaleStaging(in folder: URL, fm: FileManager) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-staleStagingAge)
        for url in entries where url.lastPathComponent.hasPrefix(stagingPrefix) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static func put(_ text: String, _ file: String, in dir: URL, fm: FileManager) throws {
        guard fm.createFile(atPath: dir.appendingPathComponent(file).path, contents: Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Moves `staging` to `name`, then `name 2`, `name 3`… — the first free
    /// one. RENAME_EXCL fails with EEXIST instead of replacing; where the
    /// volume cannot do it (ENOTSUP, EINVAL) the same walk is made with
    /// `fileExists` and a plain move.
    private static func claim(_ staging: URL, as name: String, in folder: URL, fm: FileManager,
                              rename: ExclusiveRename) throws -> URL {
        var n = 1
        var atomic = true
        while true {
            let dir = folder.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            if atomic {
                let code = rename(staging.path, dir.path)
                if code == 0 { return dir }
                if code == EEXIST { n += 1; continue }
                guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                atomic = false
            }
            if fm.fileExists(atPath: dir.path) { n += 1; continue }
            do {
                try fm.moveItem(at: staging, to: dir)
                return dir
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                n += 1
            }
        }
    }
}
