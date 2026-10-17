import Foundation

/// Where the reel export may land, kept pure: the save panel picks the place,
/// these rules keep the write safe — a folder is never a destination, and the
/// file arrives through a staged copy swapped in atomically.
public enum ReelExport {
    /// Whether the panel's destination may be written. A directory is refused:
    /// removing it to make room would delete a folder whole.
    public static func allowsDestination(isDirectory: Bool) -> Bool {
        !isDirectory
    }

    /// The staged copy's URL, next to the destination: the write stays on one
    /// volume so `replaceItemAt` can swap it in atomically, and a failed copy
    /// leaves the file that was there intact.
    public static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
    }
}
