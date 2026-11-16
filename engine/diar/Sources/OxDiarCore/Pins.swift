/// What this build is pinned to. `Package.swift` and `Package.resolved` carry the same FluidAudio
/// version; PinsTests reads Package.resolved and fails when they differ.
public enum Pins {
    public static let fluidAudioVersion = "0.18.0"
    /// Hugging Face revision of FluidInference/nemotron-3-diarization-coreml that scripts/fetch-models.sh pins
    /// (`nem_rev`; internal/config.NemotronModelsRevision is the third copy). The library's own default for this
    /// repo is the moving `main` branch, so the marker ox-diar checks is ours — `nemotronMarker`, written by the
    /// fetch script — not FluidAudio's `.fluidaudio-revision`.
    public static let nemotronModelsRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"
    public static let nemotronMarker = ".ox-say-revision"
    public static var versionLine: String {
        "ox-diar 1 (FluidAudio \(fluidAudioVersion), models \(nemotronModelsRevision.prefix(8)))"
    }
}
