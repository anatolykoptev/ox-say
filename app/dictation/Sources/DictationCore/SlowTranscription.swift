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
    public static func reason(sttServerState state: String?) -> String {
        switch state {
        case "starting":
            return "loading the speech model"
        case "stopped", "crashed":
            // The daemon falls back to a slower path while the server is down.
            return "the speech server is not running; using the slower path"
        case "off":
            return "the speech server is off"
        case "ready":
            return "decoding a long recording"
        default:
            return "the daemon did not answer"
        }
    }

    /// The daemon's /status body → `stt_server.state`.
    public static func sttServerState(fromStatus data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sttServer = obj["stt_server"] as? [String: Any] else { return nil }
        return sttServer["state"] as? String
    }
}
