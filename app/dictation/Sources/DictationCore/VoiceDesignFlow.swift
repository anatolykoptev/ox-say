import Foundation

/// What the window's design sheet asks the app to do after a step; the flow decides, the app only carries it out.
public enum VoiceDesignEffect: Equatable {
    case design(String, String)
    case play(DesignTake)
    case save(id: String, label: String, take: String, replace: Bool)
    case stopPlayback
}

/// «Описать словами»: the form, the daemon's takes, listening to them one by one until one is kept. A value type whose
/// transitions are pure: every decision (what is valid, what a taken name means, which take plays next) is here, and
/// the app carries out the `Effect` each step returns.
public struct VoiceDesignFlow: Equatable {
    public typealias Effect = VoiceDesignEffect

    public enum Phase: Equatable {
        case form
        case designing
        case reviewing(index: Int)
        case saving
        case done(savedAs: String)
        case failed(String)
    }

    public private(set) var phase: Phase = .form
    public var description: String
    public var sentence: String
    /// What the person calls the voice; empty takes the daemon's suggestion for the take kept.
    public var label: String
    public private(set) var takes: [DesignTake] = []
    /// The id a save found taken: the sheet asks before replacing it.
    public private(set) var confirmReplace: String?
    /// The first thing wrong with the form, in plain words, after a refused submit.
    public private(set) var problem: String?
    private var index = 0
    /// The id the last save went out under.
    private var sentID: String?
    /// Ids and lower-cased labels the library holds, as the last submit saw them.
    private var taken: Set<String> = []

    public init(description: String = "", sentence: String = DesignForm.defaultSentence, label: String = "") {
        self.description = description
        self.sentence = sentence
        self.label = label
    }

    /// True while the design is work the app must not lose: a version handshake never relaunches the app under it.
    public var isBusy: Bool {
        switch phase {
        case .designing, .reviewing, .saving: return true
        case .form, .done, .failed: return false
        }
    }

    /// The take under review.
    public var currentTake: DesignTake? {
        guard case .reviewing(let at) = phase, takes.indices.contains(at) else { return nil }
        return takes[at]
    }

    /// The form is answered. `taken` holds the ids and the lower-cased labels of the voices that exist: a label that
    /// names one of them is refused here, before three takes are made for it. Nothing happens outside the form.
    public mutating func submit(taken: Set<String>, text: (L10nKey) -> String = { $0.text }) -> Effect? {
        guard phase == .form else { return nil }
        if let found = DesignForm.problem(description: description, sentence: sentence, text: text) {
            problem = found
            return nil
        }
        if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let clean = VoiceLabel.clean(label) else {
                problem = text(.voicesRenameInvalid)
                return nil
            }
            if taken.contains(VoiceName.id(from: clean, taken: [])) || taken.contains(clean.lowercased()) {
                problem = text(.designProblemNameTaken)
                return nil
            }
        }
        problem = nil
        self.taken = taken
        takes = []
        index = 0
        confirmReplace = nil
        phase = .designing
        return .design(description.trimmingCharacters(in: .whitespacesAndNewlines),
                       sentence.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The daemon's takes arrived. Takes for a design that was cancelled meanwhile are dropped.
    public mutating func designed(_ made: [DesignTake], text: (L10nKey) -> String = { $0.text }) {
        guard phase == .designing else { return }
        guard !made.isEmpty else {
            phase = .failed(text(.designFailedTitle))
            return
        }
        takes = made
        index = 0
        phase = .reviewing(index: 0)
    }

    /// The next take, wrapping to the first, and the effect that plays it.
    public mutating func next() -> Effect {
        guard case .reviewing = phase, !takes.isEmpty else { return .stopPlayback }
        index = (index + 1) % takes.count
        phase = .reviewing(index: index)
        return .play(takes[index])
    }

    /// The take under review again.
    public mutating func replay() -> Effect {
        guard let take = currentTake else { return .stopPlayback }
        return .play(take)
    }

    /// Keeps the take under review: the id comes from the label typed (never one that exists), else from the daemon's
    /// suggestion for the take.
    public mutating func keep() -> Effect? {
        guard let take = currentTake else { return nil }
        let id = VoiceName.id(from: cleanLabel.isEmpty ? take.suggestedName : cleanLabel, taken: taken)
        sentID = id
        confirmReplace = nil
        phase = .saving
        return .save(id: id, label: cleanLabel, take: take.path, replace: false)
    }

    /// The daemon's answer to a save. A taken name asks before it replaces anything.
    public mutating func saveAnswered(_ outcome: SaveOutcome) {
        guard phase == .saving else { return }
        switch outcome {
        case .saved(let voice): phase = .done(savedAs: voice.name)
        case .nameTaken: confirmReplace = sentID
        }
    }

    /// The answer to "replace it?": yes saves again with replace, no goes back to the same take.
    public mutating func confirmReplaceAnswered(_ yes: Bool) -> Effect? {
        guard phase == .saving, let id = confirmReplace, let take = takesAtReview else { return nil }
        confirmReplace = nil
        guard yes else {
            phase = .reviewing(index: index)
            return nil
        }
        return .save(id: id, label: cleanLabel, take: take.path, replace: true)
    }

    /// Something went wrong while designing, saving or playing; `acknowledgeFailure` leaves it.
    public mutating func fail(_ sentence: String) {
        switch phase {
        case .designing, .reviewing, .saving:
            confirmReplace = nil
            phase = .failed(sentence)
        case .form, .done, .failed: break
        }
    }

    /// The failure was read: the form again after a failed design, the same take after a failed save or playback.
    public mutating func acknowledgeFailure() {
        guard case .failed = phase else { return }
        phase = takes.isEmpty ? .form : .reviewing(index: index)
    }

    /// Esc, Cancel or Close at any step: playback stops, the typed text stays, a label (it names one voice) does not
    /// outlive a voice that was saved.
    public mutating func cancel() -> Effect {
        if case .done = phase { label = "" }
        phase = .form
        takes = []
        index = 0
        confirmReplace = nil
        problem = nil
        return .stopPlayback
    }

    /// Esc. It returns `.stopPlayback` exactly when the sheet closes. A save in flight is not abandoned (nil, nothing
    /// changes), the replace question is answered No, and a failure is read.
    public mutating func escape() -> Effect? {
        switch phase {
        case .saving:
            if confirmReplace != nil { _ = confirmReplaceAnswered(false) }
            return nil
        case .failed:
            acknowledgeFailure()
            return nil
        case .form, .designing, .reviewing, .done:
            return cancel()
        }
    }

    /// The label as the daemon will hold it; empty when none was typed.
    private var cleanLabel: String { VoiceLabel.clean(label) ?? "" }

    private var takesAtReview: DesignTake? { takes.indices.contains(index) ? takes[index] : nil }
}

/// Whether «Описать словами» can be used now, from the daemon's own /status.
public enum DesignAvailability: Equatable {
    case available
    /// The studio voice is not installed; the Settings page offers it.
    case installable
    /// Cannot run, with the sentence that says why.
    case unavailable(String)

    public static func of(_ status: DaemonStatus?, text: (L10nKey) -> String = { $0.text }) -> DesignAvailability {
        guard let status else { return .unavailable(StudioMenu.noServiceTitle(text: text)) }
        if status.studioAvailable { return .available }
        if status.installWouldHelp { return .installable }
        return .unavailable(StudioMenu.unavailableText(reason: status.studioReason, text: text))
    }
}
