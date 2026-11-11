import DictationCore
import Foundation

/// What the Расшифровка page shows: the session's state, copied by the app.
public struct TranscribeValues: Equatable {
    /// The transcripts the daemon keeps, newest first.
    public var entries: [TranscriptEntry]
    /// How the last read of the list went; `entries` is the last good one.
    public var load: TranscribeLoad
    /// The title of the file being transcribed; nil when none is.
    public var working: String?
    /// The row the last upload produced or the person picked.
    public var selectedID: String?

    public init(entries: [TranscriptEntry] = [], load: TranscribeLoad = .loading, working: String? = nil, selectedID: String? = nil) {
        self.entries = entries
        self.load = load
        self.working = working
        self.selectedID = selectedID
    }
}
