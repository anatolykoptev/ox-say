import Foundation

/// Flushing a file to the drive before it is published.
public enum FileSync {
    /// F_FULLFSYNC: on macOS fsync leaves the data in the drive's cache, so a power cut could still lose the copy that the
    /// rename is about to publish. A volume that does not implement it (it answers ENOTSUP or EINVAL) falls back to
    /// fsync; any other failure, an I/O error above all, is the answer — a fallback that returned 0 would publish a copy
    /// the drive failed to flush. Returns nil when the data is flushed, else the errno of the failure.
    public static func durably(_ fd: Int32,
                               full: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) },
                               plain: (Int32) -> Int32 = { fsync($0) }) -> Int32? {
        if full(fd) == 0 { return nil }
        let error = errno
        guard error == ENOTSUP || error == EINVAL else { return error }
        return plain(fd) == 0 ? nil : errno
    }
}
