import Foundation

/// Whether the studio voice can be chosen on Озвучка, read from the daemon's own
/// `/status` (the same facts `DesignAvailability` and the status menu read).
public enum StudioAvailability: Equatable {
    case available
    /// The model is not downloaded (or the daemon says nothing): Settings → Add-ons offers it.
    case notInstalled
    /// This Mac cannot run it; the daemon's own reason (raw, cleaned for display by `SpeakControls.studioNote`).
    case unsupported(String)
    /// No status yet.
    case unknown

    public static func of(_ s: DaemonStatus?) -> StudioAvailability {
        guard let s else { return .unknown }
        if s.studioAvailable { return .available }
        if s.installWouldHelp { return .notInstalled }
        return .unsupported(s.studioReason ?? "")
    }
}

/// «Качество»: the fast voice works on every Mac, the studio voice needs Apple Silicon with 24 GB.
public enum SpeakEngine: String, Equatable { case fast, studio }

/// The complete list of things Озвучка may draw. A control is drawn only if it
/// changes the output on the engine that is selected (plan constraint 3), so
/// adding a case is a decision that fails the pin test until it is made on purpose.
public enum SpeakControl: String, CaseIterable {
    case voice, quality, variant, phrases, mood, loudness, pace, pause, takes, seed, cloneMode, steps
}

public enum SpeakControls {
    /// The matrix, pinned by `SpeakControlsTests`:
    /// - every engine: voice, quality, variant;
    /// - fast voice, Advanced: loudness, seed (nothing else: it has no phrases, mood, pace, pause, takes, clone mode or steps);
    /// - studio voice: phrases; mood for a designed voice (simple) or any voice (Advanced); in Advanced also
    ///   loudness, seed, pace, pause, takes, clone mode, steps.
    /// `copiesRecordingStyle` (clone_mode ultimate) hides `mood`: the daemon refuses a style next to the
    /// recording's own delivery (measured WER 0.65-0.71) and answers 409 (`deliveryModeGate`, produce_ops.go).
    public static func shown(engine: SpeakEngine, voiceIsDesigned: Bool, advanced: Bool,
                             copiesRecordingStyle: Bool = false) -> Set<SpeakControl> {
        var set: Set<SpeakControl> = [.voice, .quality, .variant]
        switch engine {
        case .fast:
            if advanced { set.formUnion([.loudness, .seed]) }
        case .studio:
            set.insert(.phrases)
            if advanced { set.formUnion([.loudness, .seed, .pace, .pause, .takes, .cloneMode, .steps]) }
            if (advanced || voiceIsDesigned) && !copiesRecordingStyle { set.insert(.mood) }
        }
        return set
    }

    /// The sentence under «Качество» when the studio voice cannot be chosen (nil when it can,
    /// and nil while the status is unknown). An unsupported reason is the daemon's own words,
    /// cleaned of terminal instructions like every other can't-run line.
    public static func studioNote(_ a: StudioAvailability, text: (L10nKey) -> String) -> String? {
        switch a {
        case .available, .unknown: return nil
        case .notInstalled: return text(.speakStudioNotInstalled)
        case .unsupported(let reason): return SpeakText.unavailableText(reason: reason, text)
        }
    }
}
