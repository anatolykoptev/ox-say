import Foundation

/// A meeting as the daemon reports it (`/v1/meetings`). Decoded by hand so an
/// added or missing field never fails the whole answer.
public struct MeetingInfo: Equatable {
    /// `unknown` carries a status a newer daemon added: the meeting stays in the list and nothing acts on it.
    public enum Status: Equatable {
        case recording, queued, transcribing, transcribed, summarizing, done, failed
        case unknown(String)

        public init(wire raw: String) {
            switch raw {
            case "recording": self = .recording
            case "queued": self = .queued
            case "transcribing": self = .transcribing
            case "transcribed": self = .transcribed
            case "summarizing": self = .summarizing
            case "done": self = .done
            case "failed": self = .failed
            default: self = .unknown(raw)
            }
        }
    }

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
    /// "auto" or "offer" when the daemon found several voices on the far side; nil otherwise.
    public var voiceMode: String?
    /// The code behind a `diarization_failed` or `diarization_unavailable` warning (`DiarProblem`).
    public var diarReason: String?
    /// The daemon's stable code for why the meeting (or its notes) failed (`fail_reason`); nil when none, or for a
    /// failure recorded before codes existed. `MeetingFailure` turns it into a sentence.
    public var failReason: String?
    /// The daemon's word that a voices retry would be accepted now (`voices_retryable`): for unavailable voices,
    /// diarization is ready, the reason is one a retry can fix, the audio is here; for a failed run, the audio is here.
    /// nil when the daemon did not say (no voices problem, or a daemon that predates the field for the failed kind).
    public var voicesRetryable: Bool?
    /// Retention removed the recording (`audio_deleted`).
    public var audioDeleted: Bool
    /// How long the call was, in seconds; nil until the recording is over.
    public var durationSeconds: Double?

    public init(id: String, dir: String? = nil, title: String = "", started: Date? = nil, status: Status,
                notesPending: String? = nil, warnings: [String] = [], error: String? = nil,
                notesMD: String? = nil, transcriptMD: String? = nil, voiceMode: String? = nil, diarReason: String? = nil,
                audioDeleted: Bool = false, durationSeconds: Double? = nil, failReason: String? = nil,
                voicesRetryable: Bool? = nil) {
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
        self.voiceMode = voiceMode
        self.diarReason = diarReason
        self.voicesRetryable = voicesRetryable
        self.audioDeleted = audioDeleted
        self.durationSeconds = durationSeconds
        self.failReason = failReason
    }

    public var heardNoSystemAudio: Bool { warnings.contains("no_system_audio") }

    /// Why the far side has one label although voices were looked for, nil when nothing went wrong.
    public var diarProblem: DiarProblem? { DiarProblem.of(warnings: warnings, reason: diarReason) }

    /// Whether "Try Again" for the voices is offered: see `DiarProblem.offersRetry`.
    public var offersVoicesRetry: Bool {
        diarProblem?.offersRetry(daemonSaysRetryable: voicesRetryable, audioDeleted: audioDeleted) ?? false
    }

    /// Nothing left for the daemon to do on its own.
    public var settled: Bool { status == .done || status == .transcribed || status == .failed }

    /// How long after its start a meeting in a status this app does not know still counts as work in progress: the 4 h
    /// that tracking a recording allows.
    public static let recentHorizon: TimeInterval = 4 * 3600

    /// Work the window should keep watching: an unsettled meeting, or one in an unknown status while it is recent. An
    /// old meeting in a status a newer daemon added is final as far as this app can tell: no spinner, no polling.
    /// A meeting with no start time cannot be shown to be recent, so it does not count; a start in the future (a wrong
    /// clock) counts only within the same horizon, so neither can keep the window polling for ever.
    public func inProgress(now: Date = Date()) -> Bool {
        if case .unknown = status {
            guard let started else { return false }
            return abs(now.timeIntervalSince(started)) < Self.recentHorizon
        }
        return !settled
    }

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
              let raw = obj["status"] as? String else { return nil }
        let status = Status(wire: raw)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let started = (obj["started"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
        return MeetingInfo(id: id, dir: obj["dir"] as? String, title: obj["title"] as? String ?? "", started: started,
                           status: status, notesPending: nonEmpty(obj["notes_pending"] as? String),
                           warnings: (obj["warnings"] as? [Any])?.compactMap { $0 as? String } ?? [], error: nonEmpty(obj["error"] as? String),
                           notesMD: nonEmpty(obj["notes_md"] as? String), transcriptMD: nonEmpty(obj["transcript_md"] as? String),
                           voiceMode: nonEmpty(obj["voice_mode"] as? String), diarReason: nonEmpty(obj["diar_reason"] as? String),
                           audioDeleted: obj["audio_deleted"] as? Bool ?? false,
                           durationSeconds: (obj["duration_s"] as? Double).flatMap { $0 > 0 ? $0 : nil },
                           failReason: nonEmpty(obj["fail_reason"] as? String),
                           voicesRetryable: obj["voices_retryable"] as? Bool)
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
    /// "engine_missing" (update ox-say), "model_missing" (a download helps), "unsupported" (this Mac cannot), or
    /// "notes_engine_failed" while `available` stays true: the last start of the notes model was refused.
    public var reasonCode: String?
    public var installing: Bool
    public var progressPercent: Int
    public var installError: String?
    /// The stable code behind `installError` ("network", "disk_full", "checksum", "other"); nil from an older daemon.
    public var installErrorCode: String?

    public init(available: Bool = false, reasonCode: String? = nil, installing: Bool = false,
                progressPercent: Int = 0, installError: String? = nil, installErrorCode: String? = nil) {
        self.available = available
        self.reasonCode = reasonCode
        self.installing = installing
        self.progressPercent = progressPercent
        self.installError = installError
        self.installErrorCode = installErrorCode
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
                           progressPercent: obj["progress_pct"] as? Int ?? 0, installError: text("install_error"), installErrorCode: text("install_error_code"))
    }
}
