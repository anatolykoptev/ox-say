import Foundation

/// What the pill says when a transcription takes longer than usual. A stall can
/// be a long decode or a speech server that is not there; the daemon's
/// `stt_server` status tells them apart.
public enum SlowTranscription {
    /// After this long the pill explains why it is still working. A long
    /// recording takes a while even on a warm GPU (a 6-minute file about 18 s),
    /// so the threshold grows with it rather than blaming length on a fault.
    public static func explainAfter(recordingSeconds: Double) -> TimeInterval {
        max(8, recordingSeconds * 0.1)
    }

    /// - Parameter sttServerState: `stt_server.state` from the daemon's
    ///   /status, nil if it could not be read (or an older daemon without it).
    public static func reason(sttServerState state: String?, text: (L10nKey) -> String = { $0.text }) -> String {
        switch state {
        case "starting":
            return text(.slowLoading)
        case "stopped", "crashed":
            // The daemon falls back to a slower path while the server is down.
            return text(.slowSlowerPath)
        case "off":
            return text(.slowOff)
        case "ready":
            return text(.slowDecoding)
        default:
            return text(.slowNoAnswer)
        }
    }

    /// The working pill after the first seconds: the elapsed time, and the reason when there is one.
    public static func pillText(seconds: Int, reason: String?, text: (L10nKey) -> String = { $0.text }) -> String {
        if let reason, !reason.isEmpty { return String(format: text(.pillTranscribingReason), String(seconds), reason) }
        return String(format: text(.pillTranscribingSeconds), String(seconds))
    }

    /// The daemon's /status body → `stt_server.state`.
    public static func sttServerState(fromStatus data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sttServer = obj["stt_server"] as? [String: Any] else { return nil }
        return sttServer["state"] as? String
    }
}
