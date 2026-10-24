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

    /// Writes the texts under `folder` and returns the meeting's subfolder. The
    /// files are written into a hidden sibling directory first and the
    /// directory is renamed into place, so a failed write leaves nothing half
    /// done in the user's folder. A taken name (two meetings in one minute)
    /// gets " 2", " 3"… from the rename itself failing with EEXIST, so nothing
    /// is overwritten even by a concurrent writer.
    @discardableResult
    public static func write(info: MeetingInfo, in folder: URL, fm: FileManager = .default,
                             timeZone: TimeZone = .current) throws -> URL {
        guard info.notesMD != nil || info.transcriptMD != nil else { throw ExportError.nothingToWrite }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folderName(title: info.title, started: info.started ?? Date(), timeZone: timeZone)
        let staging = folder.appendingPathComponent(".ox-say-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            if let notes = info.notesMD { try put(notes, "notes.md", in: staging, fm: fm) }
            if let text = info.transcriptMD { try put(text, "transcript.md", in: staging, fm: fm) }
            return try claim(staging, as: name, in: folder)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func put(_ text: String, _ file: String, in dir: URL, fm: FileManager) throws {
        guard fm.createFile(atPath: dir.appendingPathComponent(file).path, contents: Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Renames `staging` to `name`, then `name 2`, `name 3`… — the first the
    /// kernel accepts. RENAME_EXCL fails with EEXIST instead of replacing.
    private static func claim(_ staging: URL, as name: String, in folder: URL) throws -> URL {
        var n = 1
        while true {
            let dir = folder.appendingPathComponent(n == 1 ? name : "\(name) \(n)", isDirectory: true)
            if renamex_np(staging.path, dir.path, UInt32(RENAME_EXCL)) == 0 { return dir }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            n += 1
        }
    }
}
