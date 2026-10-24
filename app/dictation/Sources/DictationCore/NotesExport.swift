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

    /// Writes the texts again into the subfolder an earlier `write` made, for notes that were written
    /// again after the speakers were named. Each file is replaced atomically; a folder the user has
    /// since moved or deleted is an error (the caller then writes a new copy).
    public static func refresh(info: MeetingInfo, at dir: URL, fm: FileManager = .default) throws {
        guard info.notesMD != nil || info.transcriptMD != nil else { throw ExportError.nothingToWrite }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw CocoaError(.fileNoSuchFile) }
        if let notes = info.notesMD { try Data(notes.utf8).write(to: dir.appendingPathComponent("notes.md"), options: .atomic) }
        if let text = info.transcriptMD { try Data(text.utf8).write(to: dir.appendingPathComponent("transcript.md"), options: .atomic) }
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
