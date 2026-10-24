import Foundation

/// The meeting calls to the ox-say daemon, on the studio client's transport
/// and error handling.
extension StudioClient {
    /// POST /v1/meetings: opens a meeting and returns the directory to record into.
    public func createMeeting(title: String, source: String, me: String, them: String, echoRisk: Bool) async throws -> MeetingInfo {
        let body = try JSONSerialization.data(withJSONObject: [
            "title": title, "source": source, "labels": ["me": me, "them": them], "echo_risk": echoRisk,
        ] as [String: Any])
        let data = try await succeed(post("v1/meetings", body: body, timeout: Self.quickTimeout))
        guard let info = MeetingInfo.decode(data), info.dir != nil else { throw StudioError.badResponse }
        return info
    }

    /// POST /v1/meetings/{id}/finish: the recording is over; transcription starts.
    public func finishMeeting(id: String, timeout: TimeInterval = StudioClient.quickTimeout) async throws -> MeetingInfo {
        let data = try await succeed(post("v1/meetings/\(id)/finish", body: nil, timeout: timeout))
        guard let info = MeetingInfo.decode(data) else { throw StudioError.badResponse }
        return info
    }

    /// GET /v1/meetings/{id}, with the notes and transcript texts when asked.
    public func meeting(id: String, withTexts: Bool = false) async throws -> MeetingInfo {
        var request = get("v1/meetings/\(id)")
        if withTexts, let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "include", value: "notes,transcript")]
            request.url = parts.url
        }
        let data = try await succeed(request)
        guard let info = MeetingInfo.decode(data) else { throw StudioError.badResponse }
        return info
    }

    /// GET /v1/meetings: newest first.
    public func meetings() async throws -> [MeetingInfo] {
        let data = try await succeed(get("v1/meetings"))
        guard let list = MeetingInfo.decodeList(data) else { throw StudioError.badResponse }
        return list
    }

    /// POST /v1/meetings/{id}/notes: write the notes again (after the model arrived).
    public func retryMeetingNotes(id: String) async throws {
        _ = try await succeed(post("v1/meetings/\(id)/notes", body: nil, timeout: Self.quickTimeout))
    }

    /// PUT /v1/meetings/settings: how long the daemon keeps audio (0 = forever).
    public func setMeetingRetention(days: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["retention_days": days])
        var request = post("v1/meetings/settings", body: body, timeout: Self.quickTimeout)
        request.httpMethod = "PUT"
        _ = try await succeed(request)
    }

    /// POST /v1/meetings/notes-model/install: download the notes model.
    public func installNotesModel() async throws {
        _ = try await succeed(post("v1/meetings/notes-model/install", body: nil, timeout: Self.quickTimeout))
    }
}
