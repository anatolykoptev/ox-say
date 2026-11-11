import Foundation

/// One transcript the daemon keeps (`GET /v1/transcripts`).
public struct TranscriptEntry: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var created: Date
    public var seconds: Double
    public var engine: String
    public var language: String?

    public init(id: String, title: String, created: Date, seconds: Double, engine: String, language: String? = nil) {
        self.id = id
        self.title = title
        self.created = created
        self.seconds = seconds
        self.engine = engine
        self.language = language
    }

    /// An id is put into a URL path, so only the characters the daemon's ids are made of are accepted (a stored
    /// `../x` is not a row).
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func decode(_ obj: [String: Any]) -> TranscriptEntry? {
        guard let id = obj["id"] as? String, isSafeID(id), let created = obj["created"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = iso.date(from: created) ?? plain.date(from: created) else { return nil }
        return TranscriptEntry(id: id, title: obj["title"] as? String ?? "", created: date,
                               seconds: obj["seconds"] as? Double ?? 0, engine: obj["engine"] as? String ?? "",
                               language: (obj["language"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `{"transcripts":[…]}`; no list, or a null one, is an empty one. Rows that do not parse are skipped.
    public static func decodeList(_ data: Data) -> [TranscriptEntry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch obj["transcripts"] {
        case nil, is NSNull: return []
        case let list as [[String: Any]]: return list.compactMap(decode)
        default: return nil
        }
    }

    public static func decode(_ data: Data) -> TranscriptEntry? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap(decode)
    }

    /// "12 мин · 30 октября": the length (never "0 min") and the day it was made.
    public func subtitle(locale: Locale, calendar: Calendar, text: (L10nKey) -> String = { $0.text }) -> String {
        let minutes = String(format: text(.transcribeMinutes), String(max(1, Int((seconds / 60).rounded()))))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return "\(minutes) · \(formatter.string(from: created))"
    }
}

/// The text formats the daemon serves for a transcript (`GET /v1/transcripts/{id}?format=`).
public enum TranscriptFormat: String, Equatable {
    case text, srt, vtt, json
    case oxJSON = "ox_json"

    public var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .json, .oxJSON: return "json"
        }
    }

    /// The simple mode's button label; nil for the formats that sit under «Ещё».
    public var simpleLabelKey: L10nKey? {
        switch self {
        case .text: return .transcribeText
        case .srt: return .transcribeSubtitles
        case .vtt, .json, .oxJSON: return nil
        }
    }

    /// The title as a file name: path characters become "-", and a blank title takes `fallback`.
    public func fileName(forTitle title: String, fallback: String = L10nKey.transcribeDefaultName.text) -> String {
        let cleaned = title.map { "/:\\\0\n\r".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? fallback : name).\(fileExtension)"
    }
}

extension StudioClient {
    /// The upload's time limit: the recording's length twice over, never under the daemon's own 600 s per transcription plus
    /// the queue (the daemon's `OX_SAY_STT_TIMEOUT_SECS` default is 600; whoever raises one raises both).
    public static func transcribeTimeout(forSeconds seconds: Double?) -> TimeInterval {
        max(900, 2 * (seconds ?? 0))
    }

    /// POST /v1/transcripts: transcribes the file and keeps the result. The body is a multipart file on disk, streamed
    /// by the transport; it is removed when the call ends. A nil `engine` leaves the choice to the daemon, and an empty
    /// language or prompt is not sent.
    public func transcribeFile(_ url: URL, title: String, engine: String?, language: String?, prompt: String?,
                               seconds: Double? = nil) async throws -> TranscriptEntry {
        var fields = ["title": title]
        for (name, value) in [("model", engine), ("language", language), ("prompt", prompt)] {
            if let value, !value.isEmpty { fields[name] = value }
        }
        let boundary = "ox-say-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        do {
            try MultipartFile.write(file: url, fields: fields, boundary: boundary, to: body)
        } catch {
            throw StudioError.fileUnreadable
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcripts"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.transcribeTimeout(forSeconds: seconds)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await upload(request, body)
        } catch let error as URLError where error.code == .timedOut {
            throw StudioError.timedOut
        } catch {
            throw StudioError.daemonUnreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw Self.refusal(status: status, body: data) }
        guard let entry = TranscriptEntry.decode(data) else { throw StudioError.badResponse }
        return entry
    }

    /// GET /v1/transcripts, newest first.
    public func transcripts() async throws -> [TranscriptEntry] {
        let data = try await succeed(get("v1/transcripts"))
        guard let list = TranscriptEntry.decodeList(data) else { throw StudioError.badResponse }
        return list
    }

    /// GET /v1/transcripts/{id}?format=: the document as the daemon writes it, bytes untouched.
    public func transcriptText(id: String, format: TranscriptFormat) async throws -> Data {
        var request = get("v1/transcripts/\(id)", timeout: Self.meetingTextsTimeout)
        if let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "format", value: format.rawValue)]
            request.url = parts.url
        }
        return try await succeed(request)
    }

    /// DELETE /v1/transcripts/{id}.
    public func deleteTranscript(id: String) async throws {
        _ = try await succeed(delete("v1/transcripts/\(id)"))
    }
}
