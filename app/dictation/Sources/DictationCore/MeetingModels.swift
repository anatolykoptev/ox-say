import Foundation

/// A meeting as the daemon reports it (`/v1/meetings`). Decoded by hand so an
/// added or missing field never fails the whole answer.
public struct MeetingInfo: Equatable {
    public enum Status: String { case recording, queued, transcribing, transcribed, summarizing, done, failed }

    public var id: String
    /// The directory the app writes me.pcm and them.pcm into; set on create.
    public var dir: String?
    public var title: String
    public var started: Date?
    public var status: Status
    /// Why the notes are not there yet: "model_missing" or "failed".
    public var notesPending: String?
    /// "no_system_audio" when the other side was never heard.
    public var warnings: [String]
    public var error: String?
    public var notesMD: String?
    public var transcriptMD: String?

    public init(id: String, dir: String? = nil, title: String = "", started: Date? = nil, status: Status,
                notesPending: String? = nil, warnings: [String] = [], error: String? = nil,
                notesMD: String? = nil, transcriptMD: String? = nil) {
        self.id = id
        self.dir = dir
        self.title = title
        self.started = started
        self.status = status
        self.notesPending = notesPending
        self.warnings = warnings
        self.error = error
        self.notesMD = notesMD
        self.transcriptMD = transcriptMD
    }

    public var heardNoSystemAudio: Bool { warnings.contains("no_system_audio") }

    /// Nothing left for the daemon to do on its own.
    public var settled: Bool { status == .done || status == .transcribed || status == .failed }

    public static func decode(_ data: Data) -> MeetingInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(obj)
    }

    /// `{"meetings":[…]}`.
    public static func decodeList(_ data: Data) -> [MeetingInfo]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["meetings"] as? [[String: Any]] else { return nil }
        return list.compactMap(decode)
    }

    static func decode(_ obj: [String: Any]) -> MeetingInfo? {
        guard let id = obj["id"] as? String, !id.isEmpty,
              let raw = obj["status"] as? String, let status = Status(rawValue: raw) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let started = (obj["started"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
        return MeetingInfo(id: id, dir: obj["dir"] as? String, title: obj["title"] as? String ?? "", started: started,
                           status: status, notesPending: nonEmpty(obj["notes_pending"] as? String),
                           warnings: obj["warnings"] as? [String] ?? [], error: nonEmpty(obj["error"] as? String),
                           notesMD: nonEmpty(obj["notes_md"] as? String), transcriptMD: nonEmpty(obj["transcript_md"] as? String))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// The `notes` value of the daemon's `/status`: whether notes can be written,
/// and the model download's progress.
public struct NotesStatus: Equatable {
    public var available: Bool
    /// "engine_missing" (update ox-say), "model_missing" (a download helps), "unsupported" (this Mac cannot).
    public var reasonCode: String?
    public var installing: Bool
    public var progressPercent: Int
    public var installError: String?

    public init(available: Bool = false, reasonCode: String? = nil, installing: Bool = false,
                progressPercent: Int = 0, installError: String? = nil) {
        self.available = available
        self.reasonCode = reasonCode
        self.installing = installing
        self.progressPercent = progressPercent
        self.installError = installError
    }

    /// The download is what the daemon says would fix it.
    public var downloadWouldHelp: Bool { !available && !installing && reasonCode == "model_missing" }

    static func decode(_ obj: [String: Any]?) -> NotesStatus {
        guard let obj else { return NotesStatus() }
        func text(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return NotesStatus(available: obj["available"] as? Bool ?? false, reasonCode: text("reason_code"),
                           installing: obj["installing"] as? Bool ?? false,
                           progressPercent: obj["progress_pct"] as? Int ?? 0, installError: text("install_error"))
    }
}
