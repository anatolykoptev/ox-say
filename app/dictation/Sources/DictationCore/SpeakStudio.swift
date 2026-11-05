import Foundation

/// A studio project as Озвучка starts it.
public struct StudioStart: Equatable {
    public var script: String
    public var title: String
    public var format: ProduceFormat
    public var options: VoiceoverOptions
}

public enum SpeakStudio {
    /// The project for the editor's text: the trimmed script (what `SpeakInputCheck` counts for the studio voice), titled by
    /// its first words, as the long format. Every project from Озвучка is created with `clone_mode: "reference"`: under `auto`
    /// a designed voice with a `ref_text` resolves to ultimate (`jobCloneMode`), and the daemon then answers 409 to any mood
    /// change (`deliveryModeGate`, internal/daemon/produce_ops.go). The Advanced «Манера записи» switch (a later task) is the
    /// one thing that may choose otherwise. nil for a text with nothing to voice.
    public static func start(text: String) -> StudioStart? {
        let script = ScriptLimit.script(from: text)
        guard !script.isEmpty else { return nil }
        return StudioStart(script: script, title: SpeakClips.title(of: script), format: .long,
                           options: VoiceoverOptions(cloneMode: "reference"))
    }

    /// The studio voice only while it is chosen and this Mac can run it; otherwise the fast voice, never a job that cannot run.
    public static func engine(chosen: SpeakEngine, studio: StudioAvailability) -> SpeakEngine {
        chosen == .studio && studio == .available ? .studio : .fast
    }
}

/// #490: while Озвучка is in view and the daemon does not answer, the page asks again by itself and backs off.
public enum SpeakRecheck {
    /// Seconds until the next status read, nil when none is due.
    public static func delay(visible: Bool, section: MainSection, reach: DaemonReach, misses: Int) -> TimeInterval? {
        guard visible, section == .speak, case .unreachable = reach else { return nil }
        return VoiceoverFollower.delay(afterFailures: max(0, misses - 1))
    }
}
