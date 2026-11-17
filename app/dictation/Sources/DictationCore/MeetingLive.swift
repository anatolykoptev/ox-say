import Foundation

/// Which channel of the call a live caption came from.
public enum LiveChannel: String, Equatable {
    /// The microphone: what the user said.
    case me
    /// Everything else the Mac played: the other people.
    case them
}

/// One live caption (`GET /v1/meetings/{id}/live`): a stretch of speech recognized while the call is still going.
/// A preview: the transcript made after the call replaces it.
public struct LiveCaption: Equatable, Identifiable {
    /// Counts from 1 across the meeting and only grows: the cursor of the poll.
    public var seq: Int
    public var channel: LiveChannel
    /// Seconds into the recording.
    public var start: Double
    public var end: Double
    public var text: String

    public var id: Int { seq }

    public init(seq: Int, channel: LiveChannel, start: Double, end: Double, text: String) {
        self.seq = seq
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
    }
}

/// What the daemon says about its captioning of one meeting.
public struct LiveCaptionState: Equatable {
    /// Live captions are switched on in the daemon.
    public var enabled: Bool
    public var recording: Bool
    /// A worker is captioning this meeting now.
    public var active: Bool
    /// The captions are behind (held back for a dictation, memory or power, or the speech engine is out of reach).
    public var lagging: Bool
    /// Why a caption was held the last time (`dictation`, `memory`, `power`), nil when it was not.
    public var paused: String?
    /// `recognizer` or `disk` while the worker cannot do its job.
    public var problem: String?

    public init(enabled: Bool = true, recording: Bool = true, active: Bool = true, lagging: Bool = false,
                paused: String? = nil, problem: String? = nil) {
        self.enabled = enabled
        self.recording = recording
        self.active = active
        self.lagging = lagging
        self.paused = paused
        self.problem = problem
    }
}

/// One poll's answer.
public struct LiveAnswer: Equatable {
    public var captions: [LiveCaption]
    public var next: Int
    public var state: LiveCaptionState

    public init(captions: [LiveCaption], next: Int, state: LiveCaptionState) {
        self.captions = captions
        self.next = next
        self.state = state
    }

    /// nil for an answer that is not the daemon's shape. A caption of a channel this app does not know, or without
    /// text, is left out of `captions`; `next` still counts it, because the daemon numbered it.
    public static func decode(_ data: Data) -> LiveAnswer? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["segments"] as? [[String: Any]], let next = obj["next"] as? Int else { return nil }
        let captions: [LiveCaption] = rows.compactMap { row in
            guard let seq = row["seq"] as? Int, let channel = (row["channel"] as? String).flatMap(LiveChannel.init(rawValue:)),
                  let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return LiveCaption(seq: seq, channel: channel, start: row["start"] as? Double ?? 0, end: row["end"] as? Double ?? 0, text: text)
        }
        let s = obj["state"] as? [String: Any] ?? [:]
        let state = LiveCaptionState(enabled: s["enabled"] as? Bool ?? true, recording: s["recording"] as? Bool ?? true,
                                     active: s["active"] as? Bool ?? false, lagging: s["lagging"] as? Bool ?? false,
                                     paused: (s["paused"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                     problem: (s["problem"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        return LiveAnswer(captions: captions, next: next, state: state)
    }
}

/// The captions of one meeting as the window holds them, and where to ask next. A poll that arrives twice, late or
/// out of order never repeats a line or drops one: only a caption past the cursor is added, and the cursor moves
/// to the caption added, never past one this feed has not seen.
public struct LiveFeed: Equatable {
    public private(set) var captions: [LiveCaption] = []
    /// The `after` of the next poll: the last caption held (0: none yet).
    public private(set) var cursor = 0
    public private(set) var state: LiveCaptionState?
    /// Polls that failed one after another; an answer resets it.
    public private(set) var failures = 0

    public init() {}

    /// A poll that got no answer (the daemon down, a 404, a 500).
    public mutating func pollFailed() { failures += 1 }

    /// Several failed polls in a row: the window says it cannot read the captions and asks less often.
    public var unreadable: Bool { failures >= LivePolling.failuresBeforeBackoff }

    public mutating func apply(_ answer: LiveAnswer) {
        failures = 0
        state = answer.state
        for caption in answer.captions where caption.seq > cursor {
            captions.append(caption)
            cursor = caption.seq
        }
        // A caption this app cannot read (a channel it does not know) still moved the daemon's cursor: follow it, or
        // every poll would fetch the same unreadable line again.
        if answer.next > cursor, answer.captions.allSatisfy({ $0.seq <= cursor }) { cursor = answer.next }
    }
}

/// When the open window asks for live captions: only while it is visible and the chosen meeting is being recorded.
public enum LivePolling {
    public static let interval: TimeInterval = 2
    /// After this many failed polls in a row the poll slows to `backoffInterval`.
    public static let failuresBeforeBackoff = 3
    public static let backoffInterval: TimeInterval = 10

    /// How long to wait before the next poll.
    public static func delay(failures: Int) -> TimeInterval {
        failures >= failuresBeforeBackoff ? backoffInterval : interval
    }

    public static func needed(visible: Bool, selected: MeetingInfo?) -> Bool {
        guard visible, let selected else { return false }
        return selected.status == .recording
    }
}

/// The sentence under the live view when the captions are not simply flowing; nil when they are.
public enum LiveNotice {
    /// The feed's notice: unreadable polls first, then what the daemon said.
    public static func key(for feed: LiveFeed) -> L10nKey? {
        feed.unreadable ? .meetingLiveUnreadable : key(for: feed.state)
    }

    public static func key(for state: LiveCaptionState?) -> L10nKey? {
        guard let state else { return nil }
        if !state.enabled { return .meetingLiveOff }
        if state.problem != nil { return .meetingLiveUnavailable }
        if state.lagging { return .meetingLiveBehind }
        return nil
    }
}

extension StudioClient {
    /// GET /v1/meetings/{id}/live?after=N: the captions after the cursor, with the daemon's state.
    public func liveCaptions(id: String, after: Int) async throws -> LiveAnswer {
        var request = get(try meetingPath(id, "/live"))
        if let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "after", value: String(max(0, after)))]
            request.url = parts.url
        }
        let data = try await succeed(request)
        guard let answer = LiveAnswer.decode(data) else { throw StudioError.badResponse }
        return answer
    }
}

/// Which meeting the window reads live captions for, and which it has been told are over. A meeting that answered
/// "not recording" is never targeted again: when the list read after it fails, its row still says "recording", and a
/// target taken from that row would start a new request at once, again and again.
public struct LiveTargeting: Equatable {
    public private(set) var stopped: Set<String> = []

    public init() {}

    /// `/live` said the recording is over.
    public mutating func reportedStopped(_ id: String) { stopped.insert(id) }

    /// The chosen meeting while it is recording, else the recording the plate shows (`recordingID`: the app's own
    /// recording), because its row shows the last line. nil when the window is not visible or nothing qualifies.
    public func target(visible: Bool, selected: MeetingInfo?, meetings: [MeetingInfo], recordingID: String?) -> String? {
        guard visible else { return nil }
        if let selected, selected.status == .recording, !stopped.contains(selected.id) { return selected.id }
        guard let recordingID, !stopped.contains(recordingID) else { return nil }
        return meetings.first { $0.id == recordingID && $0.status == .recording }?.id
    }
}
