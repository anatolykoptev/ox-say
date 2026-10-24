/// What this build is pinned to. `Package.swift` and `Package.resolved` carry the same FluidAudio
/// version; PinsTests reads Package.resolved and fails when they differ.
public enum Pins {
    public static let fluidAudioVersion = "0.17.7"
    /// Hugging Face revision of FluidInference/speaker-diarization-coreml that scripts/fetch-models.sh pins: the one
    /// FluidAudio 0.17.7 itself asks for (a test compares it with `Repo.diarizer.revision`), so the loader accepts the
    /// revision marker without an override.
    public static let modelsRevision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    public static var versionLine: String {
        "ox-diar 1 (FluidAudio \(fluidAudioVersion), models \(modelsRevision.prefix(8)))"
    }
}
