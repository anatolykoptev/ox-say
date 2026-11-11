import Foundation

/// How the last read of the transcripts list went.
public enum TranscribeLoad: Equatable {
    case loading
    case loaded
    /// The sentence the user reads.
    case failed(String)
}

/// What the Расшифровка page shows. One decision: a failed read can never look like an empty list, and a refresh never
/// blanks a list that is already on screen.
public enum TranscribePageState: Equatable {
    /// The daemon could not be read and there is nothing else to show.
    case offline(String)
    case loading
    case empty
    /// The list, with the sentence for a failed refresh when the shown list is the last good one.
    case list(stale: String?)
    /// A file is being transcribed (named); the list, if any, stays under it.
    case working(name: String)

    public static func of(load: TranscribeLoad, hasItems: Bool, working: String?) -> TranscribePageState {
        if let working { return .working(name: working) }
        switch load {
        case .loading: return hasItems ? .list(stale: nil) : .loading
        case .failed(let sentence): return hasItems ? .list(stale: sentence) : .offline(sentence)
        case .loaded: return hasItems ? .list(stale: nil) : .empty
        }
    }
}
