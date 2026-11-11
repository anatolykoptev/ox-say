import Foundation

/// What a voiceover's row in the window can do. The Studio menu's modal alerts (finished, stop, continue) are these buttons now.
public enum SpeakRowAction: Hashable {
    case stop
    case continueOnBattery
    /// An interrupted project goes on from where it stopped.
    case resume
    case showInFinder
    case save
    /// A finished project whose automatic checks left this many parts for the person to listen to.
    case listenToFlagged(Int)
    case remove

    /// Stop and remove cannot be undone, so the window asks first (a window-modal confirmation, never an alert over every app).
    public var needsConfirmation: Bool { self == .stop || self == .remove }

    public func title(_ t: (L10nKey) -> String) -> String {
        switch self {
        case .stop: return t(.speakStop)
        case .continueOnBattery: return t(.speakContinueBattery)
        case .resume: return t(.speakResume)
        case .showInFinder: return t(.speakShowInFinder)
        case .save: return t(.speakSave)
        case .listenToFlagged(let n): return String(format: t(.speakListenFlagged), n)
        case .remove: return t(.speakRemove)
        }
    }

    /// The confirmation's words (title, text, the button that goes ahead); nil for an action that does not ask.
    public func confirmation(_ t: (L10nKey) -> String) -> (title: String, text: String, confirm: String)? {
        switch self {
        case .stop: return (t(.speakStopTitle), t(.speakStopText), t(.speakStopConfirm))
        case .remove: return (t(.speakRemoveTitle), t(.speakRemoveText), t(.speakRemoveConfirm))
        default: return nil
        }
    }
}

public enum SpeakRowActions {
    /// The buttons of a project's row, by what the daemon says it is doing. A finished file is offered only while there is one.
    public static func of(job: ProduceJob) -> [SpeakRowAction] {
        let hasFile = job.outputPath != nil
        switch job.status {
        case .running, .waitingForDictation:
            return [.stop]
        case .pausedOnBattery:
            return [.continueOnBattery, .stop]
        case .interrupted:
            return [.resume, .remove]
        case .review:
            var actions: [SpeakRowAction] = []
            if job.partsToReview > 0 { actions.append(.listenToFlagged(job.partsToReview)) }
            if hasFile { actions += [.showInFinder, .save] }
            return actions + [.remove]
        case .done:
            return (hasFile ? [.showInFinder, .save] : []) + [.remove]
        case .failed, .cancelled:
            return [.remove]
        case .unknown:
            return []
        }
    }

    /// Carries out the actions the daemon owns; returns false for the ones that are the window's own (Finder, the save panel,
    /// the first flagged phrase), which send nothing. The confirmation, where there is one, has been answered by then.
    @discardableResult
    public static func perform(_ action: SpeakRowAction, id: String, client: StudioClient) async throws -> Bool {
        switch action {
        case .stop: try await client.stopVoiceover(id: id)
        case .continueOnBattery: try await client.continueOnBattery(id: id)
        case .resume: try await client.resume(id: id)
        case .remove: try await client.removeVoiceover(id: id)
        case .showInFinder, .save, .listenToFlagged: return false
        }
        return true
    }
}

/// The notification that tells a voiceover has ended while the window was not showing it.
public enum VoiceoverReady {
    public struct Notice: Equatable {
        public var title: String
        public var body: String
        /// The project a click on the notification opens in the window.
        public var speakID: String
    }

    /// nil for a project stopped on purpose, and for one the window shows right now (`FinishNotice.windowShows`): the
    /// notification would only take the focus. The words are the finish alert's (`ProduceText.finishAlert`).
    public static func notice(for job: ProduceJob, shown: ShownWindow,
                              text: (L10nKey) -> String = { $0.text }) -> Notice? {
        guard !FinishNotice.windowShows(jobID: job.id, shown),
              let (title, body) = ProduceText.finishAlert(job, text: text) else { return nil }
        return Notice(title: title, body: body, speakID: job.id)
    }
}
