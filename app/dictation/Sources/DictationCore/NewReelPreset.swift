import Foundation

/// «Новый ролик» presets the screen for a short video: the Reels format (tighter pauses, louder file) with one variant
/// per phrase, which keeps the first render quick; more variants come from «Ещё вариант» on a phrase. The clone mode is
/// `reference` as for every project made on Озвучка (see `SpeakStudio.start`).
public enum NewReelPreset {
    public static let format = ProduceFormat.short
    public static let takes = 1
    public static let cloneMode = "reference"

    /// The knobs a new reel sends; the loudness is left out, so the preset's own applies.
    public static func options() -> VoiceoverOptions {
        VoiceoverOptions(takes: takes, cloneMode: cloneMode)
    }
}
