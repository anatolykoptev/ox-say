import Foundation

/// Copies a finished meeting's notes and transcript into the user's notes
/// folder: one subfolder per meeting, "2026-10-23 14.30 Zoom call", holding
/// notes.md and transcript.md. The daemon keeps its own copy for Claude to
/// read; this one is for the user to find.
public enum NotesExport {
    /// A folder name for the meeting: local start time, then the title with
    /// every character a file name cannot carry replaced.
    public static func folderName(title: String, started: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        let base = f.string(from: started)
        return clean.isEmpty ? base : "\(base) \(String(clean.prefix(80)))"
    }

    public enum ExportError: Error, Equatable {
        case nothingToWrite
    }

    /// Writes the texts under `folder` and returns the meeting's subfolder. An
    /// existing subfolder of that name (two meetings in one minute) gets " 2",
    /// " 3"… so nothing is overwritten.
    @discardableResult
    public static func write(info: MeetingInfo, in folder: URL, fm: FileManager = .default,
                             timeZone: TimeZone = .current) throws -> URL {
        guard info.notesMD != nil || info.transcriptMD != nil else { throw ExportError.nothingToWrite }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folderName(title: info.title, started: info.started ?? Date(), timeZone: timeZone)
        var dir = folder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        if let notes = info.notesMD { try notes.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
        if let text = info.transcriptMD { try text.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8) }
        return dir
    }
}
