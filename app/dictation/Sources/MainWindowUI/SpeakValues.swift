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
    public var clips: [SpeakClip] { didSet { items = SpeakList.merge(projects: projects, clips: clips) } }
    /// The clip whose result is on screen; nil is a text that has not been voiced yet.
    public var selectedID: String?
    public var phase: SpeakPhase
    public var reach: DaemonReach
    public var playback: SpeakPlayback
    public var studio: StudioAvailability
    public var advanced: Bool
    /// «Качество» as the person set it. The engine a request really uses is `engine`: the studio voice only when it can run.
    public var quality: SpeakEngine
    /// The daemon's studio projects, newest first (`GET /v1/produce`), with the one the app follows already merged in.
    public var projects: [ProduceJob] { didSet { items = SpeakList.merge(projects: projects, clips: clips) } }
    /// The list on the left, merged once when a source changes (the page reads it on every redraw).
    public private(set) var items: [SpeakListItem]
    /// The last poll of the followed voiceover got no answer: its numbers may be old.
    public var serviceWaiting: Bool
    /// Projects whose track could not be read (moved or deleted).
    public var trackMissing: Set<String>
    /// The selected item's waveform bars, 0...1; empty while they are being read or when the audio is not a PCM WAV.
    public var peaks: [Float]
    /// How far into the selected track the sound is, 0...1; moves only while it plays.
    public var playedFraction: Double

    public init(text: String = "", voice: String? = nil, clips: [SpeakClip] = [],
                selectedID: String? = nil, phase: SpeakPhase = .idle, reach: DaemonReach = .unknown,
                playback: SpeakPlayback = .stopped, studio: StudioAvailability = .unknown, advanced: Bool = false,
                quality: SpeakEngine = .fast, projects: [ProduceJob] = [], serviceWaiting: Bool = false,
                trackMissing: Set<String> = [], peaks: [Float] = [], playedFraction: Double = 0) {
        self.text = text
        self.voice = voice
        self.clips = clips
        self.selectedID = selectedID
        self.phase = phase
        self.reach = reach
        self.playback = playback
        self.studio = studio
        self.advanced = advanced
        self.quality = quality
        self.projects = projects
        self.serviceWaiting = serviceWaiting
        self.trackMissing = trackMissing
        self.peaks = peaks
        self.playedFraction = playedFraction
        items = SpeakList.merge(projects: projects, clips: clips)
    }

    public var selectedClip: SpeakClip? { clips.first { $0.id == selectedID } }
    public var selectedProject: ProduceJob? { projects.first { $0.id == selectedID } }

    /// What the voice really uses: the studio voice only while it is chosen and can run.
    public var engine: SpeakEngine { SpeakStudio.engine(chosen: quality, studio: studio) }
}
