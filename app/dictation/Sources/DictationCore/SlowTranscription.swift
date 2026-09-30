import Foundation

/// What the pill says when a transcription takes longer than usual. The two
/// slow cases look the same from outside, a spinner that keeps spinning, so the
/// daemon's engine state tells them apart.
public enum SlowTranscription {
    /// After this long the pill explains why it is still working. A long
    /// recording takes a while even on a warm GPU (a 6-minute file about 18 s),
    /// so the threshold grows with it rather than blaming the GPU for length.
    public static func explainAfter(recordingSeconds: Double) -> TimeInterval {
        max(8, recordingSeconds * 0.1)
    }

    /// - Parameter engineState: `engine.state` from the daemon's /status, nil if
    ///   it could not be read.
    public static func reason(engineState: String?) -> String {
        switch engineState {
        case "ready", "starting":
            // The daemon keeps speech-to-text off the GPU while the voice
            // engine holds it.
            return "on the CPU while the voice engine is loaded"
        default:
            // A new ox-stt compiles its GPU shaders on its first GPU run.
            return "first run after an update: preparing the GPU"
        }
    }

    /// The daemon's /status body → `engine.state`.
    public static func engineState(fromStatus data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engine = obj["engine"] as? [String: Any] else { return nil }
        return engine["state"] as? String
    }
}
