import Foundation

/// Which of the two files plays: the one that was picked, or the one that was cleaned.
public enum CleanSide: Equatable {
    case original
    case cleaned
}

/// The listening comparison of a finished cleanup: one position, two files. Switching sides keeps the position and whether
/// it is playing, so the same word is heard before and after. The app's player carries out the effects; this decides them.
public struct CleanPlayback: Equatable {
    public var side: CleanSide
    public var isPlaying: Bool
    /// Seconds into the file; the same for both sides, whose lengths differ by milliseconds.
    public var position: Double
    /// Seconds in all, once the player knows.
    public var duration: Double?

    /// What the player has to do.
    public enum Effect: Equatable {
        /// Load this side at `position` and start it when `play`.
        case load(side: CleanSide, position: Double, play: Bool)
        case play
        case pause
        case seek(Double)
    }

    public init(side: CleanSide = .cleaned, isPlaying: Bool = false, position: Double = 0, duration: Double? = nil) {
        self.side = side
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
    }

    /// A click on a side. The side already chosen does nothing.
    public mutating func choose(_ side: CleanSide) -> Effect? {
        guard side != self.side else { return nil }
        self.side = side
        return .load(side: side, position: position, play: isPlaying)
    }

    /// The play/pause button. Nothing has been loaded before the first press: it loads the chosen side from the start.
    public mutating func toggle(loaded: Bool) -> Effect {
        if !loaded {
            isPlaying = true
            return .load(side: side, position: position, play: true)
        }
        isPlaying.toggle()
        return isPlaying ? .play : .pause
    }

    /// A drag of the position slider.
    public mutating func seek(to seconds: Double) -> Effect {
        position = max(0, min(seconds, duration ?? seconds))
        return .seek(position)
    }

    /// The player's own report while it plays.
    public mutating func tick(position: Double, duration: Double?) {
        self.position = max(0, position)
        if let duration { self.duration = duration }
    }

    /// The file played to its end: stopped, and the next press starts it over.
    public mutating func ended() {
        isPlaying = false
        position = 0
    }
}
