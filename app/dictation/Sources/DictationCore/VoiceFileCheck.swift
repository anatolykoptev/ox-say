import Foundation

/// Whether the picked file can become a voice. Pure: the app measures the clip (AVURLAsset for the duration, the
/// file's size for readability) and hands the numbers in; the daemon's own limits are the rule. The daemon decodes
/// through ffmpeg (`internal/voices`), normalizes the clip and keeps at most `refSeconds` of it
/// (`voices.MaxRefSeconds`, internal/voices/refcut.go — the engine's 20 s reference cap); the studio voice's encoder
/// window is `studioRefSeconds` (`voxMaxRefSeconds`, internal/daemon/voxcpm2.go).
public enum VoiceFileCheck {
    /// Extensions the file is picked among — what the daemon's ffmpeg decodes. The picker's audio+movie filter lets
    /// more through (`.aac`, `.wma`, …): those are refused by `problem`.
    public static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "flac", "caf", "ogg",
                                                     "opus", "mp4", "mov"]
    /// A shorter clip makes a voice that hears too little of the speaker.
    public static let minimumSeconds = 3.0
    /// voices.MaxRefSeconds: a stored reference keeps at most the first 20 s, whatever came in.
    public static let refSeconds = 20.0
    /// voxMaxRefSeconds: the studio encoder's reference window — nothing past it can be used.
    public static let studioRefSeconds = 30.0

    /// The first reason the file may not be sent, in plain words; nil when it may. A clip whose duration the app
    /// could not measure (`seconds` nil) is not refused here — the daemon's own 400 sentence is what the sheet shows
    /// when it answers. Without the studio voice, no clip is refused on length alone: the daemon accepts it and cuts
    /// the reference at `refSeconds` (the warning says so); with it, a clip past `studioRefSeconds` is refused.
    public static func problem(seconds: Double?, bytes: Int64, ext: String, studioInstalled: Bool,
                               text: (L10nKey) -> String = { $0.text }) -> String? {
        guard audioExtensions.contains(ext.lowercased()) else { return text(.fileProblemNotAudio) }
        guard bytes > 0 else { return text(.fileProblemUnreadable) }
        guard let seconds else { return nil }
        if seconds < minimumSeconds { return text(.fileProblemTooShort) }
        if studioInstalled, seconds > studioRefSeconds { return text(.fileProblemTooLong) }
        return nil
    }

    /// What the clip loses by being longer than a voice keeps; nil when it is sent whole. A warning, never a
    /// refusal; where `problem` already refuses the clip (past the studio window) it stands alone.
    public static func warning(seconds: Double?, studioInstalled: Bool,
                               text: (L10nKey) -> String = { $0.text }) -> String? {
        guard let seconds, seconds > refSeconds else { return nil }
        if studioInstalled, seconds > studioRefSeconds { return nil }
        return text(.fileWarningLong)
    }
}
