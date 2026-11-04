import DictationCore
import Foundation

/// Whether a clip sounds now.
public enum SpeakPlayback: Equatable { case stopped, playing, paused }

/// What the Озвучка page shows. Plain values: the app fills them, the screenshot harness fills them with samples.
public struct SpeakValues: Equatable {
    /// The editor's text, as typed. The fast voice sends it exactly as typed.
    public var text: String
    /// The voice id for the request; nil is «Стандартный голос» (the engine's default).
    public var voice: String?
    /// This session's takes, newest first.
    public var clips: [SpeakClip]
    /// The clip whose result is on screen; nil is a text that has not been voiced yet.
    public var selectedID: String?
    public var phase: SpeakPhase
    public var reach: DaemonReach
    public var playback: SpeakPlayback
    public var studio: StudioAvailability
    public var advanced: Bool

    public init(text: String = "", voice: String? = nil, clips: [SpeakClip] = [],
                selectedID: String? = nil, phase: SpeakPhase = .idle, reach: DaemonReach = .unknown,
                playback: SpeakPlayback = .stopped, studio: StudioAvailability = .unknown, advanced: Bool = false) {
        self.text = text
        self.voice = voice
        self.clips = clips
        self.selectedID = selectedID
        self.phase = phase
        self.reach = reach
        self.playback = playback
        self.studio = studio
        self.advanced = advanced
    }

    public var selectedClip: SpeakClip? { clips.first { $0.id == selectedID } }
}
