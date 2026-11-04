/// What this build is pinned to. scripts/fetch-models.sh (`clean_rev`) and internal/config (`CleanModelsRevision`)
/// carry the same commit; `TestCleanPinsAgreeAcrossLanguages` reads all three.
public enum Pins {
    /// Hugging Face revision of Koptev/mossformer2-se-48k-coreml.
    public static let modelsRevision = "da0d6b45be2fe7f2ec495ee76280132848a789c0"
    public static let version = "ox-clean 1 (model " + String(modelsRevision.prefix(8)) + ")"
}
