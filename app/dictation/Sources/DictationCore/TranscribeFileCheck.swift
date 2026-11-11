import Foundation

/// Whether a picked or dropped file may be sent to be transcribed. Pure: the app hands in the file's size and extension.
/// The daemon's own cap is `OX_SAY_STT_MAX_UPLOAD_MB` (default 200); a file over it would be uploaded in full and then
/// refused with a 413, so it is refused here, before the upload.
public enum TranscribeFileCheck {
    /// The daemon's default upload cap, in bytes.
    public static let maxBytes = 200 << 20
    /// What the daemon's ffmpeg decodes: the voice picker's audio and video containers, plus the common video ones.
    public static let extensions: Set<String> = VoiceFileCheck.audioExtensions.union(["m4v", "webm", "mkv", "avi", "aac"])

    /// The first reason the file may not be sent, in plain words; nil when it may.
    public static func problem(bytes: Int64, ext: String, text: (L10nKey) -> String = { $0.text }) -> String? {
        guard extensions.contains(ext.lowercased()) else { return text(.transcribeProblemNotMedia) }
        guard bytes > 0 else { return text(.fileProblemUnreadable) }
        if bytes > maxBytes { return String(format: text(.transcribeProblemTooBig), String(maxBytes >> 20)) }
        return nil
    }
}
