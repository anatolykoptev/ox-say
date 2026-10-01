/// How a transcriber served the dictation it just finished: which path the
/// text came from and what was still unsent when the key was released.
public struct TranscriberStats: Equatable {
    public enum Path: String {
        /// The streaming session delivered the text.
        case stream
        /// Streaming was attempted and failed; the recording was re-uploaded.
        case fallback
        /// No streaming at all: the recording was uploaded once at release.
        case oneShot = "one-shot"
    }

    public var path: Path
    /// From `begin` to the session id; nil when no session opened before the
    /// release (the one-shot path, a failed create, or one still in flight).
    public var sessionCreateMs: Int?
    /// Segments the session had decoded before the release.
    public var segmentsBeforeRelease: Int
    /// Audio not yet sent when the key was released, in seconds.
    public var tailSeconds: Double

    public init(path: Path, sessionCreateMs: Int? = nil, segmentsBeforeRelease: Int = 0,
                tailSeconds: Double = 0) {
        self.path = path
        self.sessionCreateMs = sessionCreateMs
        self.segmentsBeforeRelease = segmentsBeforeRelease
        self.tailSeconds = tailSeconds
    }
}

/// One dictation's timing, logged once per dictation: what the latency targets
/// (release to paste, warm and after an idle stop) are measured against on
/// real use. It carries no text: the dictation itself never reaches a log.
public struct DictationTiming: Equatable {
    public enum Outcome: String {
        case delivered, empty, failed
    }

    public var recordedSeconds: Double
    /// From the release (or the toggle's second press) to the text.
    public var releaseToTextMs: Int
    public var stats: TranscriberStats
    public var outcome: Outcome

    public init(recordedSeconds: Double, releaseToTextMs: Int, stats: TranscriberStats, outcome: Outcome) {
        self.recordedSeconds = recordedSeconds
        self.releaseToTextMs = releaseToTextMs
        self.stats = stats
        self.outcome = outcome
    }

    /// The log line: key=value pairs, fixed order, no text.
    public var line: String {
        var parts = [
            "outcome=\(outcome.rawValue)",
            "path=\(stats.path.rawValue)",
            "recorded_s=\(Self.seconds(recordedSeconds))",
            "release_to_text_ms=\(releaseToTextMs)",
            "tail_s=\(Self.seconds(stats.tailSeconds))",
            "segments_before_release=\(stats.segmentsBeforeRelease)",
        ]
        parts.append("session_create_ms=\(stats.sessionCreateMs.map(String.init) ?? "none")")
        return parts.joined(separator: " ")
    }

    private static func seconds(_ s: Double) -> String {
        String(format: "%.2f", s)
    }
}
