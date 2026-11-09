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
    /// «Новый ролик»: the draft is a short video, so «Озвучить» sends the Reels preset (`NewReelPreset`).
    public var reel: Bool
    /// A document is being read into the editor.
    public var reading: Bool
    /// The chunks of the selected finished project (one read of `GET /v1/produce/{id}/chunks`) and the project they belong to.
    public var phraseChunks: [ProduceChunkDetail]
    public var phrasesFor: String?
    /// The phrase the daemon is working on, nil when none.
    public var phraseWork: PhraseWork?
    /// The phrase whose take sounds now, nil when the track or nothing does.
    public var playingPhrase: Int?
    /// The voice each project of this session was started with (the daemon's summary does not name it): the mood chips
    /// are drawn for a designed voice only (plan decision D8), and a project of an earlier session has none recorded.
    public var projectVoices: [String: String]
    /// What the person set in the Advanced voice panel for the next voicing (the app keeps it as view preferences).
    public var panel: VoicePanelSettings
    /// The panel is open (a view state, so the screenshots can open it).
    public var panelShown: Bool
    /// The phrase pace, pause and mood go to, and «Ко всему тексту» (every phrase instead of that one).
    public var panelPhrase: Int?
    public var panelAllText: Bool
    /// The projects of this session that were made with the recording's own delivery (`SpeakStudio.copiesRecording`): the daemon
    /// answers 409 to a mood on them, so none is offered.
    public var projectCopies: Set<String>
    /// Moves when a change to a phrase was refused or has landed, so the panel's sliders start again from the stored value.
    public var panelEpoch: Int

    public init(text: String = "", voice: String? = nil, clips: [SpeakClip] = [],
                selectedID: String? = nil, phase: SpeakPhase = .idle, reach: DaemonReach = .unknown,
                playback: SpeakPlayback = .stopped, studio: StudioAvailability = .unknown, advanced: Bool = false,
                quality: SpeakEngine = .fast, projects: [ProduceJob] = [], serviceWaiting: Bool = false,
                trackMissing: Set<String> = [], peaks: [Float] = [], playedFraction: Double = 0,
                reel: Bool = false, reading: Bool = false, phraseChunks: [ProduceChunkDetail] = [], phrasesFor: String? = nil,
                phraseWork: PhraseWork? = nil, playingPhrase: Int? = nil, projectVoices: [String: String] = [:],
                panel: VoicePanelSettings = VoicePanelSettings(), panelShown: Bool = false, panelPhrase: Int? = nil,
                panelAllText: Bool = false, projectCopies: Set<String> = [], panelEpoch: Int = 0) {
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
        self.reel = reel
        self.reading = reading
        self.phraseChunks = phraseChunks
        self.phrasesFor = phrasesFor
        self.phraseWork = phraseWork
        self.playingPhrase = playingPhrase
        self.projectVoices = projectVoices
        self.panel = panel
        self.panelShown = panelShown
        self.panelPhrase = panelPhrase
        self.panelAllText = panelAllText
        self.projectCopies = projectCopies
        self.panelEpoch = panelEpoch
        items = SpeakList.merge(projects: projects, clips: clips)
    }

    public var selectedClip: SpeakClip? { clips.first { $0.id == selectedID } }
    public var selectedProject: ProduceJob? { projects.first { $0.id == selectedID } }

    /// The phrases of the selected project, ready to draw; empty until its chunks were read.
    public var phrases: [PhraseRowValue] {
        guard let job = selectedProject, phrasesFor == job.id else { return [] }
        return PhraseEditing.rows(chunks: phraseChunks, jobRunning: !job.status.isTerminal)
    }

    /// The mood chips are drawn for the selected project (`PhraseEditing.showsMood`).
    public func showsMood(voices: [VoiceEntry]) -> Bool {
        PhraseEditing.showsMood(voice: selectedID.flatMap { projectVoices[$0] }, voices: voices, advanced: advanced, copiesRecordingStyle: copiesRecordingStyle)
    }

    /// The delivery the project on screen was made with, or, with none open, the one the next project will get.
    public var copiesRecordingStyle: Bool {
        selectedProject.map { projectCopies.contains($0.id) } ?? panel.copiesRecording
    }

    /// What the voice really uses: the studio voice only while it is chosen and can run.
    public var engine: SpeakEngine { SpeakStudio.engine(chosen: quality, studio: studio) }
}
