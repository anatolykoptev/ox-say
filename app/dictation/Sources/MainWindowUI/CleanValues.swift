import DictationCore
import Foundation

/// What the cleanup bar on the Расшифровка page shows: the session's state and the listening comparison, copied by the app.
public struct CleanValues: Equatable {
    public var state: CleanActionState
    public var playback: CleanPlayback

    public init(state: CleanActionState = .idle(firstUse: false), playback: CleanPlayback = CleanPlayback()) {
        self.state = state
        self.playback = playback
    }
}
