import Foundation

/// What the daemon will take: its upload cap and its per-transcription timeout. Read from `/status` (`config.stt_max_upload_mb`,
/// `config.stt_timeout_s`); a daemon that predates them is assumed to run the defaults.
public struct TranscribeLimits: Equatable {
    public var maxBytes: Int64
    public var daemonTimeout: TimeInterval

    public init(maxBytes: Int64, daemonTimeout: TimeInterval) {
        self.maxBytes = maxBytes
        self.daemonTimeout = daemonTimeout
    }

    public init(status: DaemonStatus?) {
        maxBytes = status?.sttMaxUploadMB.map { Int64($0) << 20 } ?? Self.fallback.maxBytes
        daemonTimeout = status?.sttTimeoutSeconds ?? Self.fallback.daemonTimeout
    }

    /// OX_SAY_STT_MAX_UPLOAD_MB and OX_SAY_STT_TIMEOUT_SECS defaults.
    public static let fallback = TranscribeLimits(maxBytes: 200 << 20, daemonTimeout: 600)
}

/// Whether a picked or dropped file may be sent to be transcribed. Pure: the app hands in the file's size and extension.
/// A file over the daemon's upload cap would be uploaded in full and then refused with a 413, so it is refused here, before
/// the upload (and again while it is streamed: `MultipartFile`).
public enum TranscribeFileCheck {
    /// The daemon's default upload cap, in bytes.
    public static let maxBytes = 200 << 20
    /// What the daemon's ffmpeg decodes: the voice picker's audio and video containers, plus the common video ones.
    public static let extensions: Set<String> = VoiceFileCheck.audioExtensions.union(["m4v", "webm", "mkv", "avi", "aac"])

    /// The first reason the file may not be sent, in plain words; nil when it may. `limit` is the daemon's cap in bytes.
    public static func problem(bytes: Int64, ext: String, limit: Int64 = Int64(maxBytes),
                               text: (L10nKey) -> String = { $0.text }) -> String? {
        guard extensions.contains(ext.lowercased()) else { return text(.transcribeProblemNotMedia) }
        guard bytes > 0 else { return text(.fileProblemUnreadable) }
        if bytes > limit { return String(format: text(.transcribeProblemTooBig), String(limit >> 20)) }
        return nil
    }

    /// The title a transcript is stored under: a file name as one line (control characters, a line break among them, become
    /// a space; runs of spaces collapse) and no longer than the daemon takes (`maxTitleChars`, 200).
    public static func title(fromFileName name: String) -> String {
        let flat = String(name.map { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : $0 })
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(200))
    }
}
