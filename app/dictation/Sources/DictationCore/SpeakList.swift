import Foundation

/// One row of the Озвучка list: a studio project the daemon keeps, or a take of this session.
public struct SpeakListItem: Identifiable, Equatable {
    public enum Kind: Equatable { case project(ProduceJob), clip(SpeakClip) }
    public enum State: Equatable { case running, ready, review, failed, interrupted, stopped }

    public var id: String
    public var title: String
    public var seconds: Double?
    public var created: Date
    public var kind: Kind
    public var state: State

    public init(id: String, title: String, seconds: Double?, created: Date, kind: Kind, state: State) {
        self.id = id
        self.title = title
        self.seconds = seconds
        self.created = created
        self.kind = kind
        self.state = state
    }

    /// The row's status line (the age is added by the view for rows that have a result).
    public func status(_ t: (L10nKey) -> String) -> String {
        let length = seconds.map(SpeakClips.clock) ?? ""
        switch state {
        case .running:
            if case .project(let job) = kind, job.partsTotal > 0 { return String(format: t(.speakProgressParts), job.partsDone, job.partsTotal) }
            return t(.speakProgressStarting)
        case .ready: return length
        case .review: return length.isEmpty ? t(.speakNeedsListen) : "\(length) · \(t(.speakNeedsListen))"
        case .failed: return t(.speakProgressFailed)
        case .interrupted: return t(.speakProgressInterrupted)
        case .stopped: return t(.speakProgressStopped)
        }
    }
}

public enum SpeakList {
    /// Projects and clips, newest first, a running project always before everything else.
    public static func merge(projects: [ProduceJob], clips: [SpeakClip]) -> [SpeakListItem] {
        var items = projects.map(item) + clips.map {
            SpeakListItem(id: $0.id, title: $0.title, seconds: $0.seconds, created: $0.created, kind: .clip($0), state: .ready)
        }
        items.sort { a, b in
            let (ar, br) = (a.state == .running, b.state == .running)
            if ar != br { return ar }
            if a.created != b.created { return a.created > b.created }
            return a.id < b.id
        }
        return items
    }

    private static func item(_ job: ProduceJob) -> SpeakListItem {
        let state: SpeakListItem.State
        switch job.status {
        case .running, .waitingForDictation, .pausedOnBattery, .unknown: state = .running
        case .done: state = job.error == nil ? .ready : .failed
        case .review: state = job.error == nil ? .review : .failed
        case .failed: state = .failed
        case .cancelled: state = .stopped
        case .interrupted: state = .interrupted
        }
        return SpeakListItem(id: job.id, title: job.title, seconds: job.durationS, created: job.createdAt ?? .distantPast,
                             kind: .project(job), state: state)
    }

    /// The list read with the followed voiceover on top: the follower polls every few seconds, so its copy is at least as
    /// fresh as a list read that may have started earlier. A job started a moment ago shows before the next list read.
    public static func overlay(projects: [ProduceJob], followed: ProduceJob?) -> [ProduceJob] {
        guard let followed else { return projects }
        if projects.contains(where: { $0.id == followed.id }) {
            return projects.map { $0.id == followed.id ? followed : $0 }
        }
        return [followed] + projects
    }
}

extension SpeakList {
    /// A fresh list read with the followed job: the follower's copy is newer than a read that started before its last poll
    /// only while the job is still working. A finished job's copy is as old as its last poll, and the daemon's entry may be
    /// newer (a resume or a re-render through MCP), so it wins.
    public static func afterRead(projects: [ProduceJob], followed: ProduceJob?) -> [ProduceJob] {
        guard let followed, !followed.status.isTerminal else { return projects }
        return overlay(projects: projects, followed: followed)
    }

    /// Whether the selected id still names a project or a clip (nil selects nothing and is fine).
    public static func stillPresent(_ id: String?, projects: [ProduceJob], clips: [SpeakClip]) -> Bool {
        guard let id else { return true }
        return projects.contains { $0.id == id } || clips.contains { $0.id == id }
    }
}

/// The identity of a project's audio file: it changes when the file does (a re-render rewrites it), so the waveform is
/// read again; a file that is missing has a key of its own.
public enum SpeakTrack {
    public static func key(projectID: String, path: String, modified: Date?, size: Int?) -> String {
        "project:\(projectID):\(path):\(modified.map { String($0.timeIntervalSince1970) } ?? "-"):\(size.map(String.init) ?? "-")"
    }
}

/// A studio project is on its way to the daemon. The flag belongs to the request that set it: a request that was
/// superseded (the generation moved on) never leaves «Остановить» disabled for the ones after it.
public struct StartingGate: Equatable {
    private var token: Int?
    public init() {}
    public mutating func begin(_ token: Int) { self.token = token }
    public mutating func end() { token = nil }
    public func isActive(in generation: Generation) -> Bool { token.map(generation.isCurrent) ?? false }
}

/// What the Studio menu's finish alert does once the window shows the result itself.
public enum FinishNotice {
    /// A project started on Озвучка and finished while the window is on screen is already on the page; the alert would
    /// only take the focus. Everything else keeps it: a menu project, and a window that is closed or hidden.
    public static func shouldAlert(startedOnPage: Bool, windowVisible: Bool) -> Bool { !(startedOnPage && windowVisible) }
}

/// What the detail of a selected studio project shows.
public enum SpeakProjectState: Equatable {
    /// The progress row and the bar's fill (nil: no part count yet, an indeterminate bar).
    case running(label: String, fraction: Double?)
    /// A track to play; `note` is the line about parts that need a listen.
    case ready(note: String?, seconds: Double?)
    case trackMissing
    case ended(String)

    public static func of(_ job: ProduceJob, serviceWaiting: Bool, trackMissing: Bool, _ t: (L10nKey) -> String) -> SpeakProjectState {
        switch job.status {
        case .running, .waitingForDictation, .pausedOnBattery, .unknown:
            let fraction = job.partsTotal > 0 ? min(1, max(0, Double(job.partsDone) / Double(job.partsTotal))) : nil
            return .running(label: SpeakText.progressRow(job, serviceWaiting: serviceWaiting, t), fraction: fraction)
        case .done, .review:
            if job.error != nil { return .ended(SpeakText.finishText(job, t) ?? t(.speakFinishFailed)) }
            if job.outputPath == nil || trackMissing { return .trackMissing }
            return .ready(note: job.status == .review ? SpeakText.finishText(job, t) : nil, seconds: job.durationS)
        case .failed:
            return .ended(SpeakText.finishText(job, t) ?? t(.speakFinishFailed))
        case .interrupted:
            // The menu's sentence points at its own «Озвучить» button; a project has no script to restart from here.
            return .ended(t(.speakProjectInterrupted))
        case .cancelled:
            return .ended(t(.speakProgressStopped))
        }
    }
}
