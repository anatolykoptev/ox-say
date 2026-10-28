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
    /// Audio not yet acknowledged by the session when the key was released,
    /// in seconds (a chunk still in flight counts).
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
    /// How the text reached the user, as `TextOutput.deliver` reported it;
    /// nil when nothing was delivered (an empty or failed transcription). A
    /// `delivered` outcome with the text left on the clipboard is still a
    /// delivery — `delivery=none` would claim the dictation produced nothing.
    public var delivery: Delivery?
    /// The transcription failed with the daemon unreachable and the held audio
    /// got the restart wait (see `DaemonRetry`); true whether or not the second
    /// upload then succeeded — `outcome` says how it ended.
    public var retried: Bool
    /// How long that wait took, in ms; 0 when there was none.
    public var waitedMs: Int

    public init(recordedSeconds: Double, releaseToTextMs: Int, stats: TranscriberStats, outcome: Outcome,
                delivery: Delivery?, retried: Bool = false, waitedMs: Int = 0) {
        self.recordedSeconds = recordedSeconds
        self.releaseToTextMs = releaseToTextMs
        self.stats = stats
        self.outcome = outcome
        self.delivery = delivery
        self.retried = retried
        self.waitedMs = waitedMs
    }

    /// The log line: key=value pairs, fixed order, no text. The delivery
    /// fields, then the retry fields, are appended last; every earlier key is byte-identical to before
    /// they existed — something may parse them.
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
        switch delivery {
        case .paste?:
            parts.append("delivery=paste")
        case .typed?:
            parts.append("delivery=typed")
        case .clipboardOnly(let reason)?:
            parts.append("delivery=clipboard")
            parts.append("clipboard_reason=\(reason.code)")
        case nil:
            parts.append("delivery=none")
        }
        // Only a retried dictation carries these, last: every other line stays
        // byte-identical to before the retry existed.
        if retried {
            parts.append("retried=1")
            parts.append("waited_ms=\(waitedMs)")
        }
        return parts.joined(separator: " ")
    }

    /// The log line with the id of the delivery it reports appended last, so
    /// the `paste settled` line of the same paste can be matched to it. A
    /// dictation that delivered nothing has no id.
    public func line(deliveryID: Int?) -> String {
        guard delivery != nil, let deliveryID else { return line }
        return line + " id=\(deliveryID)"
    }

    private static func seconds(_ s: Double) -> String {
        String(format: "%.2f", s)
    }
}

/// The `paste settled` log line, carrying the id of the delivery it settles.
public enum PasteSettledLog {
    public static func text(id: Int, read: Bool) -> String {
        "paste settled id=\(id) read=\(read ? "yes" : "no")"
    }
}
