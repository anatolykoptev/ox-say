import Foundation

/// «Громкость»: where the finished voice is levelled to. The numbers are the measured ones (reels −14, YouTube −16, under
/// music −18, broadcast −23); «Своё» is any level the daemon accepts, −40 to −5 (`minLUFS`, `maxLUFS` in postprocess.go).
public enum LoudnessTarget: Hashable {
    case reels, youtube, underMusic, broadcast
    case custom(Double)

    /// The daemon's accepted range.
    public static let range: ClosedRange<Double> = -40 ... -5
    /// The named choices, in the order the picker lists them.
    public static let presets: [LoudnessTarget] = [.reels, .youtube, .underMusic, .broadcast]

    /// The level sent to the daemon, always inside its range; NaN (which the daemon refuses) is the YouTube level.
    public var lufs: Double {
        switch self {
        case .reels: return -14
        case .youtube: return -16
        case .underMusic: return -18
        case .broadcast: return -23
        case .custom(let v):
            guard !v.isNaN else { return -16 }
            return min(Self.range.upperBound, max(Self.range.lowerBound, v))
        }
    }

    public var titleKey: L10nKey {
        switch self {
        case .reels: return .speakPanelLoudnessReels
        case .youtube: return .speakPanelLoudnessYoutube
        case .underMusic: return .speakPanelLoudnessUnderMusic
        case .broadcast: return .speakPanelLoudnessBroadcast
        case .custom: return .speakPanelLoudnessCustom
        }
    }

    /// The target a stored level is: a named one when it matches, «Своё» otherwise.
    public static func of(lufs: Double) -> LoudnessTarget {
        presets.first { $0.lufs == lufs } ?? .custom(LoudnessTarget.custom(lufs).lufs)
    }
}

/// «Качество» of the recording itself (Черновик 8 steps, Чистовик 10), not the page's «Обычное»/«Студийное».
public enum PanelQuality: String, Equatable {
    case draft, final
}

/// One row of the panel, by id. A struct (not the enum) so the list reads as plain strings in the pinned order.
public struct PanelRow: Equatable {
    public let id: String
}

/// Which phrases a pace, pause or mood change goes to.
public enum PanelScope: Equatable {
    case phrase(Int)
    case all
}

/// One change of the batch the panel sends as `deliver` entries.
public enum PanelChange: Equatable {
    case pace(Double)
    case pause(Double)
    case mood(Mood?)
}

/// When a row's change is heard.
public enum PanelTiming: Equatable {
    /// At once, on the project that is open, without voicing it again.
    case now
    /// With the next voicing: nothing that already exists changes.
    case nextVoicing
    /// Only a finished voiceover has phrases to change.
    case needsProject
}

/// What the person set in the panel for the next voicing. A nil is «as usual»: it is left out of the request, so the
/// daemon's own default (the format's loudness, ten steps, a random sound, the preset's takes) stays in charge.
public struct VoicePanelSettings: Equatable {
    public var loudness: LoudnessTarget?
    public var quality: PanelQuality?
    /// «Манера записи» is «Копировать подачу записи» (clone mode ultimate); off is «Только голос» (reference).
    public var copiesRecording: Bool
    public var seed: Int?
    public var takes: Int?

    public init(loudness: LoudnessTarget? = nil, quality: PanelQuality? = nil, copiesRecording: Bool = false,
                seed: Int? = nil, takes: Int? = nil) {
        self.loudness = loudness
        self.quality = quality
        self.copiesRecording = copiesRecording
        self.seed = seed
        self.takes = takes
    }

    static let keyLoudness = "speak.panel.loudness"
    static let keyQuality = "speak.panel.quality"
    static let keyCopies = "speak.panel.copies"
    static let keySeed = "speak.panel.seed"
    static let keyTakes = "speak.panel.takes"

    /// Read back from the view preferences. A missing key is «as usual»; a value out of range is brought inside it.
    public static func load(from d: UserDefaults) -> VoicePanelSettings {
        VoicePanelSettings(
            loudness: (d.object(forKey: keyLoudness) as? Double).map(LoudnessTarget.of(lufs:)),
            quality: d.string(forKey: keyQuality).flatMap(PanelQuality.init(rawValue:)),
            copiesRecording: d.bool(forKey: keyCopies),
            seed: (d.object(forKey: keySeed) as? Int).map(VoicePanelModel.seed),
            takes: (d.object(forKey: keyTakes) as? Int).map(VoicePanelModel.takes))
    }

    /// Written as view preferences (plan constraint 7: nothing here is a second store). A cleared choice removes its key.
    public func save(to d: UserDefaults) {
        func put(_ value: Any?, _ key: String) { if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) } }
        put(loudness?.lufs, Self.keyLoudness)
        put(quality?.rawValue, Self.keyQuality)
        d.set(copiesRecording, forKey: Self.keyCopies)
        put(seed, Self.keySeed)
        put(takes, Self.keyTakes)
    }
}

/// The Advanced voice panel's decisions. Pure; `SpeakSource` carries them out and `VoicePanel` draws them.
public enum VoicePanelModel {
    /// The panel's rows for the controls the matrix shows, in the fixed order. `quality` is the matrix's `steps`. The page's own
    /// «Качество», the variant button and the phrase list are not rows. Rows that only the studio voice has are dropped for the
    /// fast voice whatever the set says, so a wrong set can never draw a control that does nothing there.
    public static func rows(controls: Set<SpeakControl>, engine: SpeakEngine) -> [PanelRow] {
        let order: [(id: String, control: SpeakControl, studioOnly: Bool)] = [
            ("voice", .voice, false), ("mood", .mood, true), ("pace", .pace, true), ("pause", .pause, true),
            ("loudness", .loudness, false), ("quality", .steps, true), ("cloneMode", .cloneMode, true),
            ("seed", .seed, false), ("takes", .takes, true),
        ]
        return order.filter { controls.contains($0.control) && (engine == .studio || !$0.studioOnly) }.map { PanelRow(id: $0.id) }
    }

    /// The engine the panel speaks for: an open studio project is always the studio voice, whatever «Качество» says.
    public static func engine(chosen: SpeakEngine, projectSelected: Bool) -> SpeakEngine {
        projectSelected ? .studio : chosen
    }

    /// Pace is measured between 0.85 and 1.15 (the daemon refuses anything else but 0) on a 0.01 grid. nil is neutral: nothing
    /// to ask for. To go back to neutral on a phrase that has a pace, the entry carries 0 (`deliveryEntries`).
    public static func paceValue(_ slider: Double) -> Double? {
        guard !slider.isNaN else { return nil }
        let clamped = max(0.85, min(1.15, slider))
        let grid = (clamped * 100).rounded() / 100
        return grid == 1 ? nil : grid
    }

    /// Pause after a phrase: 0 clears, otherwise 0.05...3 s on the 0.05 grid (the daemon takes 0.05...10; a value between 0
    /// and 0.05 would be refused). NaN is no pause.
    public static func pauseValue(_ seconds: Double) -> Double {
        guard !seconds.isNaN else { return 0 }
        return Double(Int((min(3, max(0, seconds)) * 20).rounded())) / 20
    }

    /// Steps behind «Черновик» and «Чистовик»: 8 cost 19 % less time with no loss measured, 10 is the engine's default. Six are
    /// not offered: they broke other quantisations.
    public static func steps(_ quality: PanelQuality) -> Int {
        quality == .draft ? 8 : 10
    }

    /// The sound's number: 0...4294967295 (`maxVoxSeed` in voxcpm2.go).
    public static func seed(_ n: Int) -> Int { min(4_294_967_295, max(0, n)) }

    /// Variants per phrase: 1...3 (`maxTakesPerChunk`).
    public static func takes(_ n: Int) -> Int { min(3, max(1, n)) }

    /// «Копировать подачу записи» is clone mode ultimate; «Только голос» is reference (the app's default for every project).
    public static func cloneMode(copiesRecording: Bool) -> String {
        copiesRecording ? "ultimate" : "reference"
    }

    /// The options of a new studio project: the preset or default `base`, with the panel's choices on top. While Advanced is
    /// off the panel's values are ignored entirely: a control that is not drawn must not change the sound.
    public static func options(base: VoiceoverOptions, panel: VoicePanelSettings, advanced: Bool) -> VoiceoverOptions {
        guard advanced else { return base }
        var merged = base
        merged.cloneMode = cloneMode(copiesRecording: panel.copiesRecording)
        if let takes = panel.takes { merged.takes = Self.takes(takes) }
        if let loudness = panel.loudness { merged.loudness = loudness.lufs }
        if let quality = panel.quality { merged.steps = steps(quality) }
        if let seed = panel.seed { merged.seed = Self.seed(seed) }
        return merged
    }

    /// What the fast voice's request carries: the pinned sound and the level, only while Advanced is on.
    public static func speechKnobs(panel: VoicePanelSettings, advanced: Bool) -> (seed: Int?, loudness: Double?) {
        guard advanced else { return (nil, nil) }
        return (panel.seed.map(seed), panel.loudness?.lufs)
    }

    /// A level can be applied to an open project at once only when it is finished: the daemon re-assembles the finished file
    /// and answers 409 while phrases are still to render.
    public static func loudnessAppliesNow(status: ProduceStatus?) -> Bool {
        status == .done || status == .review
    }

    /// The phrases a change goes to: all of them, or the chosen one (the first when none is chosen or it is gone). nil when
    /// the project has no phrases read yet.
    public static func scope(allText: Bool, phrase: Int?, chunks: [ProduceChunkDetail]) -> PanelScope? {
        guard let first = chunks.first else { return nil }
        if allText { return .all }
        if let phrase, chunks.contains(where: { $0.index == phrase }) { return .phrase(phrase) }
        return .phrase(first.index)
    }

    /// The `deliver` entries for a change: one per phrase of the scope whose stored value differs. A pace or pause going back to
    /// neutral is an explicit 0 (a nil field means «leave it», so the old value would stay), and a phrase that already has the
    /// value is left out (an entry with nothing in it is a 400). No entries, no call.
    public static func deliveryEntries(chunks: [ProduceChunkDetail], scope: PanelScope, change: PanelChange) -> [DeliveryEntry] {
        let targets: [ProduceChunkDetail]
        switch scope {
        case .all: targets = chunks
        case .phrase(let n): targets = chunks.filter { $0.index == n }
        }
        return targets.compactMap { chunk in
            switch change {
            case .pace(let slider):
                let wanted = paceValue(slider) ?? 0
                let stored = chunk.pace == 1 ? 0 : chunk.pace
                return wanted == stored ? nil : DeliveryEntry(n: chunk.index, pace: wanted)
            case .pause(let seconds):
                let wanted = pauseValue(seconds)
                return wanted == chunk.pauseAfter ? nil : DeliveryEntry(n: chunk.index, pauseAfter: wanted)
            case .mood(let mood):
                let unchanged = mood == nil ? chunk.style == nil : PhraseEditing.mood(of: chunk.style) == mood
                return unchanged ? nil : PhraseEditing.deliveryEntry(chunk: chunk.index, mood: mood)
            }
        }
    }

    /// The sentence under a row: what happens to the sound and when. nil where a row has none to add (the panel says once that
    /// phrases need a finished voiceover).
    public static func captionKey(row: String, timing: PanelTiming, allText: Bool, copiesRecording: Bool) -> L10nKey? {
        switch (row, timing) {
        case (_, .needsProject): return nil
        case ("loudness", .now): return .speakPanelLoudnessNow
        case ("loudness", .nextVoicing): return .speakPanelLoudnessNext
        case ("pace", _), ("pause", _): return allText ? .speakPanelNowAll : .speakPanelNowPhrase
        case ("mood", _): return allText ? .speakPanelMoodNowAll : .speakPanelMoodNow
        case ("quality", _): return .speakPanelQualityHint
        case ("cloneMode", _): return copiesRecording ? .speakPanelStyleHintOn : .speakPanelStyleHint
        case ("seed", _): return .speakPanelSeedHint
        case ("takes", _): return .speakPanelTakesHint
        default: return nil
        }
    }

    /// When a row's change is heard, for the caption under it. Pace and pause re-assemble the track without a render, the mood
    /// renders the phrase again (both need a finished project); a level is applied at once to a finished project and is
    /// otherwise kept for the next voicing; steps, clone mode, takes and the sound's number exist only when a project is made.
    public static func timing(of row: String, engine: SpeakEngine, finishedProject: Bool) -> PanelTiming {
        switch row {
        case "pace", "pause", "mood": return finishedProject ? .now : .needsProject
        case "loudness": return engine == .studio && finishedProject ? .now : .nextVoicing
        default: return .nextVoicing
        }
    }
}

/// The window's width when the voice panel is a third pane of Озвучка. The window floor (`MainWindowSpec.minimumWidth`) is
/// sized for the Meetings split; with the panel open the list, the text and the panel at their least need more, so the window
/// grows by the shortfall when the panel opens (as Mail's and Pages' inspectors do) and gives it back when it closes.
public enum PanelWindow {
    /// The content width the panes need at their least: the sidebar as it is now, the list, the text, and the panel when open,
    /// with a one-point divider between neighbours.
    public static func neededWidth(sidebar: Double, list: Double, detail: Double, panel: Double, divider: Double, panelOpen: Bool) -> Double {
        sidebar + list + divider + detail + (panelOpen ? divider + panel : 0)
    }

    /// How much wider the window becomes: the shortfall, and no more than the screen has room for. Never negative.
    public static func growth(needed: Double, current: Double, room: Double) -> Double {
        max(0, min(needed - current, room))
    }

    /// The least content width the window may be dragged to: its normal floor, and with the panel open what the panes need.
    public static func minimumWidth(floor: Double, needed: Double, panelOpen: Bool) -> Double {
        panelOpen ? max(floor, needed) : floor
    }

    /// What to take back when the panel closes: only what the opening added, and never below the floor.
    public static func shrink(grewBy: Double, current: Double, floor: Double) -> Double {
        max(0, min(grewBy, current - floor))
    }
}
