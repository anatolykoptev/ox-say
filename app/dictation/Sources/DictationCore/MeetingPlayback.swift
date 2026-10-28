import Foundation

/// Whether, and how, a meeting's audio may be played now. One decision for the whole window, so the line a user clicks
/// and the button that shows cannot disagree.
public enum PlaybackGate: Equatable {
    case allowed
    /// Retention removed the audio: nothing to play, and no play affordance at all.
    case audioRemoved
    /// A recording is running: the call's audio must not come out of the speakers into it. The click is answered with
    /// the reason.
    case blockedByRecording
    /// That meeting is still being recorded; its audio is not a file yet.
    case notReady

    public static func decide(audioDeleted: Bool, recordingRunning: Bool, status: MeetingInfo.Status) -> PlaybackGate {
        if audioDeleted { return .audioRemoved }
        // An unknown status may be a recording that a newer daemon names differently: no audio file to trust yet.
        if status == .recording { return .notReady }
        if case .unknown = status { return .notReady }
        if recordingRunning { return .blockedByRecording }
        return .allowed
    }

    public var showsAffordance: Bool { self == .allowed || self == .blockedByRecording }
    public var mayPlay: Bool { self == .allowed }
}

public enum PlaybackRefusal: Equatable {
    /// A recording is running.
    case recording
    /// No audio to play from this line.
    case unavailable
}

public enum PlaybackStart: Equatable {
    case play(from: Double)
    case refused(PlaybackRefusal)
}

public enum PlaybackPlan {
    /// A click on a transcript line: play from that line's start, or the reason it does not.
    public static func start(turn: TranscriptTurn, gate: PlaybackGate) -> PlaybackStart {
        switch gate {
        case .allowed:
            guard let start = turn.startSeconds else { return .refused(.unavailable) }
            return .play(from: start)
        case .blockedByRecording: return .refused(.recording)
        case .audioRemoved, .notReady: return .refused(.unavailable)
        }
    }
}

/// A turn's time as the transcript shows it ("m:ss", "h:mm:ss") and back.
public enum TurnClock {
    public static func seconds(of time: String) -> Double? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let n = parts.compactMap { $0 }
        if n.count == 3 {
            guard n[1] < 60, n[2] < 60 else { return nil }
            return Double(n[0] * 3600 + n[1] * 60 + n[2])
        }
        guard n[1] < 60 else { return nil }
        return Double(n[0] * 60 + n[1])
    }

    /// The turn that is being spoken at `position`: the last that has begun. nil before the first.
    public static func currentTurn(at position: Double, in turns: [TranscriptTurn]) -> Int? {
        var best: (id: Int, start: Double)?
        for t in turns {
            guard let s = t.startSeconds, s <= position else { continue }
            if best == nil || s >= best!.start { best = (t.id, s) }
        }
        return best?.id
    }
}

extension TranscriptTurn {
    /// Seconds into the recording where this turn begins; nil for a time that does not read.
    public var startSeconds: Double? { TurnClock.seconds(of: time) }
}

/// Where a search hit opens.
public enum HitDestination: Equatable {
    case notes
    case transcript(start: Double?, speaker: String?)
}

extension SearchHit {
    /// A notes or title hit opens the Notes; a transcript hit opens the Transcript at its turn.
    public var destination: HitDestination {
        switch field {
        case .title, .notes: return .notes
        case .transcript: return .transcript(start: start, speaker: speaker)
        }
    }
}

public enum TurnLocator {
    /// The turn a transcript hit points at. The transcript shows whole seconds, so the turn is the one whose shown
    /// second is the hit's; two turns in one second are told apart by the speaker. A time between turns is the turn that
    /// had begun.
    public static func turnID(start: Double?, speaker: String?, in turns: [TranscriptTurn]) -> Int? {
        guard let start else { return nil }
        let second = start.rounded(.down)
        let same = turns.filter { $0.startSeconds == second }
        if let speaker, let t = same.first(where: { $0.speaker == speaker }) { return t.id }
        if let t = same.first { return t.id }
        return turns.last(where: { ($0.startSeconds ?? .infinity) <= second })?.id
    }
}

/// What the daemon says to a look at a meeting's audio.
public enum AudioProbe: Equatable {
    case available
    /// 410: retention removed it, or it never had any.
    case removed
    /// 409: that meeting is still recording.
    case stillRecording
    case failed(String)
}

extension StudioClient {
    /// The audio's address. A plain loopback URL: the daemon asks for no token (its guard checks the Host and
    /// refuses a browser's cross-site read), so AVPlayer needs no header and there is no secret to put anywhere.
    public func meetingAudioURL(id: String) -> URL {
        baseURL.appendingPathComponent("v1/meetings/\(id)/audio")
    }

    /// HEAD on the audio before the player: AVPlayer reports a 410 as an unreadable file, which cannot be told from a
    /// broken one. A removed audio is said as such.
    public func probeMeetingAudio(id: String, text: (L10nKey) -> String = { $0.text }) async -> AudioProbe {
        var request = URLRequest(url: meetingAudioURL(id: id))
        request.httpMethod = "HEAD"
        request.timeoutInterval = Self.quickTimeout
        do {
            let (data, status) = try await perform(request)
            switch status {
            case 200..<300: return .available
            case 410: return .removed
            case 409: return .stillRecording
            default: throw Self.refusal(status: status, body: data)
            }
        } catch {
            return .failed(MeetingErrorText.sentence(error, action: .audio, text: text))
        }
    }
}

/// The meeting audio that plays now, for the mini player and the highlighted line.
public struct PlaybackValues: Equatable {
    public var meetingID: String
    public var isPlaying: Bool
    /// Seconds into the recording.
    public var position: TimeInterval
    /// Seconds in all; nil until the player knows.
    public var duration: TimeInterval?

    public init(meetingID: String, isPlaying: Bool, position: TimeInterval, duration: TimeInterval? = nil) {
        self.meetingID = meetingID
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
    }

    /// Whether this differs from what was last published in a way anyone sees: the clock shows whole seconds and a
    /// turn begins on one, so a tick inside the same second changes nothing on screen. Without this every tick
    /// would re-render the whole window.
    public func publishes(after last: PlaybackValues?) -> Bool {
        guard let last else { return true }
        return meetingID != last.meetingID || isPlaying != last.isPlaying || Int(position) != Int(last.position)
            || duration.map { Int($0) } != last.duration.map { Int($0) }
    }
}

/// Which request for the audio is the live one. A click starts a HEAD probe; its answer arrives later, and by then the
/// user may have clicked another line, stopped, picked another meeting or closed the window. Only the newest request,
/// with its window still open, may start the audio. A hidden window is still open: playback goes on under another app.
public struct PlayRequestGuard {
    private var current = 0

    public init() {}

    public mutating func begin() -> Int {
        current += 1
        return current
    }

    /// Stop, switch, close: every probe on its way is now stale.
    public mutating func invalidate() { current += 1 }

    public func isCurrent(_ request: Int, windowOpen: Bool) -> Bool { request == current && windowOpen }
}
