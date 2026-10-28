import Foundation

/// One place a search matched, as `GET /v1/meetings/search` reports it.
public struct SearchHit: Equatable {
    public enum Field: String { case title, notes, transcript }

    public var field: Field
    public var snippet: String
    /// Seconds into the recording; a transcript hit only.
    public var start: Double?
    /// The name the transcript shows; a transcript hit only.
    public var speaker: String?

    public init(field: Field, snippet: String, start: Double? = nil, speaker: String? = nil) {
        self.field = field
        self.snippet = snippet
        self.start = start
        self.speaker = speaker
    }
}

public struct SearchedMeeting: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var started: Date?
    public var status: MeetingInfo.Status?
    public var hits: [SearchHit]

    public init(id: String, title: String, started: Date?, status: MeetingInfo.Status?, hits: [SearchHit]) {
        self.id = id
        self.title = title
        self.started = started
        self.status = status
        self.hits = hits
    }

    /// The meeting as the list's title rules read it (an auto title is shown in the user's language).
    public var asInfo: MeetingInfo { MeetingInfo(id: id, title: title, started: started, status: status ?? .done) }
}

/// The daemon's answer to a search. Decoded by hand, like `MeetingInfo`: a hit of a field this app does not know is
/// left out and never fails the whole answer.
public struct MeetingSearchResult: Equatable {
    public var meetings: [SearchedMeeting]
    /// More meetings matched than were returned.
    public var truncated: Bool
    /// Texts that could not be searched (unreadable, or too large).
    public var skipped: Int

    public init(meetings: [SearchedMeeting], truncated: Bool = false, skipped: Int = 0) {
        self.meetings = meetings
        self.truncated = truncated
        self.skipped = skipped
    }

    public static func decode(_ data: Data) -> MeetingSearchResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["meetings"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let meetings: [SearchedMeeting] = list.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let hits: [SearchHit] = (m["hits"] as? [[String: Any]] ?? []).compactMap { h in
                guard let raw = h["field"] as? String, let field = SearchHit.Field(rawValue: raw),
                      let snippet = h["snippet"] as? String else { return nil }
                let speaker = h["speaker"] as? String
                return SearchHit(field: field, snippet: snippet, start: h["start"] as? Double,
                                 speaker: (speaker?.isEmpty ?? true) ? nil : speaker)
            }
            let started = (m["started"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return SearchedMeeting(id: id, title: m["title"] as? String ?? "", started: started,
                                   status: (m["status"] as? String).flatMap(MeetingInfo.Status.init(rawValue:)), hits: hits)
        }
        return MeetingSearchResult(meetings: meetings, truncated: obj["truncated"] as? Bool ?? false,
                                   skipped: obj["skipped"] as? Int ?? 0)
    }

    /// One short line under the results when the answer is not the whole truth; nil when it is.
    public func footnote(text: (L10nKey) -> String = { $0.text }) -> String? {
        var parts: [String] = []
        if truncated { parts.append(text(.searchTruncated)) }
        if skipped > 0 { parts.append(String(format: text(.searchSkipped), skipped)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// What one request for a search came to.
public enum MeetingSearchAnswer: Equatable {
    case result(MeetingSearchResult)
    /// 429: two searches already run. Not a failure: ask again after this many seconds.
    case busy(retryAfter: TimeInterval)
    /// The sentence for the user.
    case failed(String)
}

extension StudioClient {
    /// GET /v1/meetings/search?q=. The query goes whole in one percent-encoded parameter ("+" and "&" are text).
    public func searchMeetings(query: String, text: (L10nKey) -> String = { $0.text }) async -> MeetingSearchAnswer {
        var request = get("v1/meetings/search")
        if let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.percentEncodedQueryItems = [URLQueryItem(name: "q", value: query.addingPercentEncoding(withAllowedCharacters: .searchValue))]
            request.url = parts.url
        }
        do {
            let (data, response) = try await performWithResponse(request)
            let status = response?.statusCode ?? 200
            switch status {
            case 200..<300:
                guard let result = MeetingSearchResult.decode(data) else { throw StudioError.badResponse }
                return .result(result)
            case 429:
                return .busy(retryAfter: MeetingSearch.retryDelay(header: response?.value(forHTTPHeaderField: "Retry-After")))
            default:
                throw Self.refusal(status: status, body: data)
            }
        } catch {
            return .failed(MeetingErrorText.sentence(error, action: .search, text: text))
        }
    }
}

extension CharacterSet {
    /// What may stand in a query value unescaped: unreserved characters only, so "+", "&", "=" and "#" are escaped.
    fileprivate static let searchValue = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// What the Meetings list shows in place of the days while a search is on.
public struct MeetingSearchState: Equatable {
    public enum Phase: Equatable {
        case idle
        case searching
        case results(MeetingSearchResult)
        case noResults
        /// The daemon stayed busy through every retry. A quiet line with a button, not an error.
        case busy
        case failed(String)
    }

    public internal(set) var phase: Phase = .idle
    /// The normalized query being searched or shown.
    public internal(set) var query = ""
    var generation = 0
    var retries = 0

    public init() {}

    /// A state as it stands, for a screenshot or a preview.
    public init(phase: Phase, query: String) {
        self.phase = phase
        self.query = query
    }
}

public enum MeetingSearchEvent: Equatable {
    case typed(String)
    case timerFired(generation: Int)
    case answered(generation: Int, MeetingSearchAnswer)
    case retry
}

public enum MeetingSearchEffect: Equatable {
    /// Cancel the timer and the request that run now.
    case cancelInFlight
    case startTimer(generation: Int, delay: TimeInterval)
    case run(generation: Int, query: String)
}

/// The window's search as a state machine with no clock and no network: a field that is typed into, a debounce, one
/// request at a time, a 429 that is tried again. The app runs the effects (a timer, a request, a cancel) and feeds the
/// events back; every event carries the generation it belongs to, so an answer or a timer of an older query is
/// dropped here, whatever a late request does.
public enum MeetingSearch {
    public static let debounce: TimeInterval = 0.25
    /// The daemon's cap on a query (`meeting.MaxQueryRunes`); longer input is cut, not refused.
    public static let maxQueryLength = 200
    public static let maxRetries = 6
    public static let maxRetryDelay: TimeInterval = 5
    /// What the daemon says when it sends no Retry-After.
    static let defaultRetryDelay: TimeInterval = 1

    /// The text to send: trimmed and cut to 200 characters; nil for blank input (the plain list).
    public static func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // The daemon counts runes (scalars), not Characters or bytes.
        let scalars = t.unicodeScalars
        guard scalars.count > maxQueryLength else { return t }
        let cut = String(String.UnicodeScalarView(scalars.prefix(maxQueryLength)))
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retry-After in seconds, never a hot loop and never a long wait.
    static func retryDelay(header: String?) -> TimeInterval {
        let seconds = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? defaultRetryDelay
        return min(max(seconds, debounce), maxRetryDelay)
    }

    public static func reduce(_ s: inout MeetingSearchState, _ event: MeetingSearchEvent) -> [MeetingSearchEffect] {
        switch event {
        case .typed(let raw):
            guard let q = normalize(raw) else {
                s.generation += 1
                s.query = ""
                s.phase = .idle
                return [.cancelInFlight]
            }
            // The same text again changes nothing, unless the last try ended badly: typing is a way to try again.
            if q == s.query {
                switch s.phase {
                case .busy, .failed, .idle: break
                default: return []
                }
            }
            s.generation += 1
            s.query = q
            s.retries = 0
            s.phase = .searching
            return [.cancelInFlight, .startTimer(generation: s.generation, delay: debounce)]
        case .timerFired(let g):
            guard g == s.generation, s.phase == .searching else { return [] }
            return [.run(generation: g, query: s.query)]
        case .answered(let g, let answer):
            guard g == s.generation, s.phase == .searching else { return [] }
            switch answer {
            case .result(let r):
                s.phase = r.meetings.isEmpty ? .noResults : .results(r)
                return []
            case .busy(let after):
                s.retries += 1
                if s.retries > maxRetries {
                    s.phase = .busy
                    return []
                }
                return [.startTimer(generation: g, delay: after)]
            case .failed(let sentence):
                s.phase = .failed(sentence)
                return []
            }
        case .retry:
            guard !s.query.isEmpty else { return [] }
            s.generation += 1
            s.retries = 0
            s.phase = .searching
            return [.cancelInFlight, .run(generation: s.generation, query: s.query)]
        }
    }
}
