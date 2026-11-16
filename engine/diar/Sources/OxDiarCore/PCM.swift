import Foundation

public enum PCMError: Error, Equatable {
    /// The file does not exist or cannot be read.
    case unreadable
    /// The file holds no sample (an odd trailing byte does not count).
    case empty
}
