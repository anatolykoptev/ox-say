import Foundation

/// The name a cleaned file is saved under, and the kinds the daemon will write. Pure: the app hands in the picked file and,
/// when it could measure it, whether the file has a picture.
public enum CleanNaming {
    /// What the daemon writes for an audio-only input, and for an input with a picture (`voiceclean` refuses any other
    /// pairing with a 400): a video container needs a picture, an audio one needs none.
    public static let audioExtensions = ["wav", "flac", "mp3", "m4a"]
    public static let videoExtensions = ["mov", "mp4", "m4v", "mkv", "webm"]

    /// Containers that hold a picture when nothing better is known; `.mp4` or `.webm` without a picture is told apart by
    /// the app's own measurement.
    private static let pictureContainers: Set<String> = Set(videoExtensions).union(["avi"])

    public static func outputExtensions(picture: Bool) -> [String] { picture ? videoExtensions : audioExtensions }

    /// Whether the file has a picture: what the app measured, else what its extension usually means.
    public static func hasPicture(_ input: URL, measured: Bool?) -> Bool {
        measured ?? pictureContainers.contains(input.pathExtension.lowercased())
    }

    /// "Интервью.mov" -> "Интервью-clean.mov"; "a.mp3" -> "a-clean.mp3"; a file that is already "-clean" gets "-clean-2", then
    /// "-clean-3", so the proposed name is never the file that was picked. An extension the daemon would refuse for this kind
    /// of file (an `.aac` sound, an `.avi` picture) becomes the nearest one it accepts: `.m4a`, `.mkv`.
    public static func defaultOutput(for input: URL, picture: Bool? = nil) -> String {
        let ext = input.pathExtension
        let withPicture = hasPicture(input, measured: picture)
        let allowed = outputExtensions(picture: withPicture)
        let outExt = allowed.contains(ext.lowercased()) ? ext : (withPicture ? "mkv" : "m4a")
        return "\(cleanedStem(input.deletingPathExtension().lastPathComponent)).\(outExt)"
    }

    private static func cleanedStem(_ stem: String) -> String {
        if stem.hasSuffix("-clean") { return stem + "-2" }
        if let range = stem.range(of: #"-clean-\d+$"#, options: .regularExpression),
           let n = Int(stem[range].dropFirst("-clean-".count)) {
            return String(stem[..<range.lowerBound]) + "-clean-\(n + 1)"
        }
        return stem + "-clean"
    }
}

/// Whether a picked or dropped file may be offered to the cleanup. The daemon's ffmpeg decides the rest (no audio, too many
/// channels), and says so in its own refusal.
public enum CleanFileCheck {
    /// The first reason the file may not be cleaned, in plain words; nil when it may.
    public static func problem(ext: String, text: (L10nKey) -> String = { $0.text }) -> String? {
        TranscribeFileCheck.extensions.contains(ext.lowercased()) ? nil : text(.transcribeProblemNotMedia)
    }
}
