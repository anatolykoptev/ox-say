/// How the last read of the voice library went.
public enum VoicesLoad: Equatable {
    case loading
    case loaded
    /// The sentence the user reads.
    case failed(String)
}

/// What the Voices page shows. One decision, like MeetingsPageState: a failed
/// read can never look like an empty library, and a refresh never blanks a
/// list that is already on screen.
public enum VoicesPageState: Equatable {
    case loading
    /// The daemon could not be read and there is nothing else to show.
    case unreachable(String)
    case empty
    /// The list, with the sentence for a failed refresh when the shown list is the last good one.
    case list(stale: String?)

    public static func of(load: VoicesLoad, hasVoices: Bool) -> VoicesPageState {
        switch load {
        case .loading: return hasVoices ? .list(stale: nil) : .loading
        case .failed(let sentence): return hasVoices ? .list(stale: sentence) : .unreachable(sentence)
        case .loaded: return hasVoices ? .list(stale: nil) : .empty
        }
    }
}
