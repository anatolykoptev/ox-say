import Foundation

/// How the last read of the meeting list went.
public enum MeetingsLoad: Equatable {
    case loading
    case loaded
    /// The sentence the user reads.
    case failed(String)
}

/// What the Meetings page shows. One decision, so a failed read can never look like an empty list and a refresh
/// never blanks a list that is already on screen.
public enum MeetingsPageState: Equatable {
    case off
    case loading
    /// The daemon could not be read and there is nothing else to show.
    case unreachable(String)
    case empty
    /// The list (and the recording bar), with the sentence for a failed refresh when the shown list is the last good one.
    case list(stale: String?)

    public static func of(enabled: Bool, load: MeetingsLoad, hasMeetings: Bool, recording: Bool) -> MeetingsPageState {
        guard enabled else { return .off }
        let something = hasMeetings || recording
        switch load {
        case .loading: return something ? .list(stale: nil) : .loading
        case .failed(let sentence): return something ? .list(stale: sentence) : .unreachable(sentence)
        case .loaded: return something ? .list(stale: nil) : .empty
        }
    }
}

/// When the open window asks the daemon again. Nothing runs while the window is closed, hidden or covered, or when
/// every meeting is settled and the notes writer is not downloading.
public enum MeetingsPolling {
    public static let interval: TimeInterval = 3

    public static func needed(visible: Bool, meetings: [MeetingInfo], writer: NotesWriterState = .ready, now: Date = Date()) -> Bool {
        guard visible else { return false }
        if case .downloading = writer { return true }
        return meetings.contains { $0.inProgress(now: now) }
    }
}

/// One read of everything at a time; a request that comes while one runs is not lost but runs once more afterwards
/// (a delete, a rename or a started recording asks for a read exactly while another is in flight).
public struct RefreshGate: Equatable {
    private var running = false
    private var again = false

    public init() {}

    /// True when the caller should start a read now.
    public mutating func request() -> Bool {
        if running { again = true; return false }
        running = true
        return true
    }

    /// The read ended. True when another pass is due.
    public mutating func finish() -> Bool {
        if again { again = false; return true }
        running = false
        return false
    }
}

/// Why a meeting call cannot even be tried.
public enum MeetingFeatureError: Error, Equatable {
    case needsNewerMacOS
    case switchedOff
}

/// What the user was doing when a call to the daemon failed: the sentence differs ("rename it when it is done").
public enum MeetingAction: CaseIterable, Equatable {
    case refresh, rename, delete, speakers, retry, settings, search, audio
    /// Closing a recording that was running.
    case finish
}

/// A failed call in the user's language and plain words. The daemon's own refusal texts are English; only the ones
/// with no mapping carry them through.
public enum MeetingErrorText {
    public static func sentence(_ error: Error, action: MeetingAction, text: (L10nKey) -> String = { $0.text }) -> String {
        if let error = error as? MeetingFeatureError {
            return text(error == .needsNewerMacOS ? .meetingErrNeedsMac : .meetingErrOff)
        }
        guard let error = error as? StudioError else { return text(.meetingErrGeneric) }
        switch error {
        case .daemonUnreachable: return text(.meetingErrDaemonDown)
        case .timedOut: return text(.meetingErrTimeout)
        case .badResponse: return text(.meetingErrBadResponse)
        case .refused(let status, _):
            // The daemon's own words are English and name internals: they never reach the window.
            switch (status, action) {
            case (409, .delete): return text(.meetingErrDeleteBusy)
            case (409, .rename): return text(.meetingErrRenameBusy)
            case (409, _): return text(.meetingErrBusy)
            case (404, _): return text(.meetingErrNotFound)
            case (400, .rename): return text(.meetingErrRenameInvalid)
            case (400, .settings): return text(.meetingErrSettingsInvalid)
            default: return text(.meetingErrGeneric)
            }
        }
    }

    /// A delete of a meeting the daemon no longer has: the wish is already true, so the list is refreshed, not scolded.
    public static func isAlreadyGone(_ error: Error, action: MeetingAction) -> Bool {
        guard action == .delete, case StudioError.refused(404, _) = error else { return false }
        return true
    }
}

extension MeetingRowModel {
    /// What to say about a recording that did not finish, in the user's language. The daemon's reason is free English
    /// text that names internals, so it is not shown; the sentence is the app's own for the daemon's `fail_reason` code. nil for a fine recording.
    public static func failureSentence(of info: MeetingInfo, text: (L10nKey) -> String = { $0.text }) -> String? {
        MeetingFailureNotice.of(info, text: text)?.sentence
    }

    /// The title the list shows. A title the app itself gave a call ("Zoom call") is shown in the user's language; any
    /// other title, including one the user typed, is shown as it is. What is stored never changes.
    public static func displayTitle(of info: MeetingInfo, text: (L10nKey) -> String = { $0.text }) -> String {
        let t = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source = CallPolicy.sources.first(where: { MeetingLimits.title(forSource: $0) == t }),
           let name = CallPolicy.names[source] {
            return String(format: text(.meetingsTitleCall), name)
        }
        return title(of: info, text: text)
    }
}

/// Notes are written from what other people said on a call: a link in them is theirs, not ours, and must not be one
/// click from the user's browser, and no image of theirs may load.
public enum InlineMarkdown {
    public static func attributed(_ markdown: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnly))) ?? AttributedString(markdown)
        return removingLinks(parsed)
    }

    public static func removingLinks(_ text: AttributedString) -> AttributedString {
        var out = text
        for run in out.runs {
            if run.link != nil { out[run.range].link = nil }
            // A Markdown image is a link with a picture: a view that loads image attributes would fetch it on open.
            if run.imageURL != nil { out[run.range].imageURL = nil }
        }
        return out
    }
}

/// Where "Show in Finder" goes for a meeting: the folder the app copied it to, else the notes folder, else nowhere
/// (the window says so). The daemon's own meeting directory is not shown to users and is not in its answers.
public enum MeetingFolderTarget: Equatable {
    case copy(URL)
    case notesFolder(URL)
    case nowhere

    public static func resolve(exportPath: String?, notesFolder: URL, exists: (String) -> Bool) -> MeetingFolderTarget {
        if let exportPath, exists(exportPath) { return .copy(URL(fileURLWithPath: exportPath, isDirectory: true)) }
        if exists(notesFolder.path) { return .notesFolder(notesFolder) }
        return .nowhere
    }
}

/// The reads of an open meeting's detail: one in flight per meeting, so a polling pass cannot stack up reads against
/// a busy daemon, and the answer of a read that was given up (the meeting was deleted) never lands.
public struct DetailReads: Equatable {
    public struct Outcome: Equatable {
        /// The answer belongs to the latest read of this meeting and may be shown.
        public var apply: Bool
        /// Another read was asked for while this one ran.
        public var rerun: Bool
    }

    private var inFlight: [String: Int] = [:]
    private var again: Set<String> = []
    private var counter = 0

    public init() {}

    /// A token to start a read with, or nil when one is already running (it will be followed by one more).
    public mutating func request(_ id: String) -> Int? {
        if inFlight[id] != nil { again.insert(id); return nil }
        counter += 1
        inFlight[id] = counter
        return counter
    }

    public mutating func finish(_ id: String, token: Int) -> Outcome {
        guard inFlight[id] == token else { return Outcome(apply: false, rerun: false) }
        inFlight[id] = nil
        return Outcome(apply: true, rerun: again.remove(id) != nil)
    }

    /// The running read of `id` is given up: its answer is dropped and the next request starts a new one.
    public mutating func cancel(_ id: String) {
        inFlight[id] = nil
        again.remove(id)
    }
}
