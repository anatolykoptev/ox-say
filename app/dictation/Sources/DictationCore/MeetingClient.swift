import Foundation

/// The meeting calls to the ox-say daemon, on the studio client's transport
/// and error handling.
extension StudioClient {
    /// POST /v1/meetings: opens a meeting and returns the directory to record into.
    public func createMeeting(title: String, source: String, me: String, them: String, speaker: String = "", echoRisk: Bool) async throws -> MeetingInfo {
        // The daemon answers 400 to a text over its caps; a long display name must not stop a recording (#252).
        var labels = ["me": MeetingLimits.clamp(me, to: MeetingLimits.labelMax), "them": MeetingLimits.clamp(them, to: MeetingLimits.labelMax)]
        if !speaker.isEmpty { labels["speaker"] = MeetingLimits.clamp(speaker, to: MeetingLimits.labelMax) }
        let body = try JSONSerialization.data(withJSONObject: [
            "title": MeetingLimits.clamp(title, to: MeetingLimits.titleMax), "source": MeetingLimits.clamp(source, to: MeetingLimits.sourceMax),
            "labels": labels, "echo_risk": echoRisk,
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
        if withTexts { request.timeoutInterval = Self.meetingTextsTimeout }
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

    /// POST /v1/meetings/{id}/voices: tell the far side's voices apart again (the voice engine broke the first
    /// time). The daemon transcribes the meeting again, which `retryMeetingNotes` never does.
    public func retryMeetingVoices(id: String) async throws {
        _ = try await succeed(post("v1/meetings/\(id)/voices", body: nil, timeout: Self.quickTimeout))
    }

    /// PATCH /v1/meetings/{id}: the user's title. Trimmed and cut to the daemon's cap first (the daemon answers 400 to
    /// a longer one). The answer is the meeting as it is now.
    public func renameMeeting(id: String, title: String) async throws -> MeetingInfo {
        let body = try JSONSerialization.data(withJSONObject: ["title": MeetingLimits.clamp(title, to: MeetingLimits.titleMax)])
        var request = post("v1/meetings/\(id)", body: body, timeout: Self.quickTimeout)
        request.httpMethod = "PATCH"
        let data = try await succeed(request)
        guard let info = MeetingInfo.decode(data) else { throw StudioError.badResponse }
        return info
    }

    /// DELETE /v1/meetings/{id}: removes the meeting from the daemon. A meeting that is recording or being processed
    /// answers 409 (`StudioError.refused(status: 409, …)`).
    public func deleteMeeting(id: String) async throws {
        var request = get("v1/meetings/\(id)")
        request.httpMethod = "DELETE"
        _ = try await succeed(request)
    }

    /// GET /v1/meetings/settings: what the daemon itself keeps (how long the audio stays).
    public func meetingDaemonSettings() async throws -> MeetingDaemonSettings {
        let data = try await succeed(get("v1/meetings/settings"))
        guard let settings = MeetingDaemonSettings.decode(data) else { throw StudioError.badResponse }
        return settings
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

    /// GET /v1/meetings/{id}/speakers: the far side's speakers as the transcript shows them.
    public func speakers(id: String) async throws -> SpeakersState {
        let data = try await succeed(get("v1/meetings/\(id)/speakers"))
        guard let state = SpeakersState.decode(data) else { throw StudioError.badResponse }
        return state
    }

    /// PATCH /v1/meetings/{id}/speakers: names, merges and the split. The daemon writes the transcript
    /// again and queues the notes to be written again; the answer is the new state.
    public func editSpeakers(id: String, edits: SpeakerEdits) async throws -> SpeakersState {
        var request = post("v1/meetings/\(id)/speakers", body: edits.body(), timeout: Self.quickTimeout)
        request.httpMethod = "PATCH"
        let data = try await succeed(request)
        guard let state = SpeakersState.decode(data) else { throw StudioError.badResponse }
        return state
    }
}
