import Foundation

/// Where a voiceover export may land, kept pure: the save panel picks the
/// place, these rules keep the write safe — a folder is never a destination,
/// and the file arrives through a staged copy swapped in atomically.
public enum ExportRules {
    /// Whether the panel's destination may be written. A directory is refused:
    /// removing it to make room would delete a folder whole.
    public static func allowsDestination(isDirectory: Bool) -> Bool {
        !isDirectory
    }

    /// Puts a copy of `source` at `destination` without ever losing what is there: the copy is staged beside the destination
    /// and swapped in atomically, so a copy that fails (a full disk, a read error) leaves the old file as it was, and the
    /// staged remainder is taken down. Choosing the source itself as the destination does nothing.
    public static func install(_ source: URL, to destination: URL, fm: FileManager = .default,
                               copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        if sameFile(source, destination, fm: fm) { return }
        let staged = stagingURL(for: destination)
        do {
            try copy(source, staged)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Whether two URLs name one file, through symlinks and hard links.
    static func sameFile(_ a: URL, _ b: URL, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path) else { return false }
        if a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path { return true }
        let ids = [a, b].map { try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier }
        if let x = ids[0], let y = ids[1] { return x.isEqual(y) }
        return false
    }

    /// The staged copy's URL, next to the destination: the write stays on one
    /// volume so `replaceItemAt` can swap it in atomically, and a failed copy
    /// leaves the file that was there intact.
    public static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
    }
}
