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

/// When the open window asks the daemon again. Nothing runs while the window is closed or every meeting is settled.
public enum MeetingsPolling {
    public static let interval: TimeInterval = 3

    public static func needed(visible: Bool, meetings: [MeetingInfo]) -> Bool {
        visible && meetings.contains { !$0.settled }
    }
}

/// What the user was doing when a call to the daemon failed: the sentence differs ("rename it when it is done").
public enum MeetingAction: CaseIterable, Equatable {
    case refresh, rename, delete, speakers, retry, settings
}

/// A failed call in the user's language and plain words. The daemon's own refusal texts are English; only the ones
/// with no mapping carry them through.
public enum MeetingErrorText {
    public static func sentence(_ error: Error, action: MeetingAction, text: (L10nKey) -> String = { $0.text }) -> String {
        guard let error = error as? StudioError else { return text(.meetingErrGeneric) }
        switch error {
        case .daemonUnreachable: return text(.meetingErrDaemonDown)
        case .timedOut: return text(.meetingErrTimeout)
        case .badResponse: return text(.meetingErrBadResponse)
        case .refused(let status, let message):
            if status == 409 {
                switch action {
                case .delete: return text(.meetingErrDeleteBusy)
                case .rename: return text(.meetingErrRenameBusy)
                case .refresh, .speakers, .retry, .settings: return text(.meetingErrBusy)
                }
            }
            return String(format: text(.meetingErrRefused), message)
        }
    }

    /// A delete of a meeting the daemon no longer has: the wish is already true, so the list is refreshed, not scolded.
    public static func isAlreadyGone(_ error: Error, action: MeetingAction) -> Bool {
        guard action == .delete, case StudioError.refused(404, _) = error else { return false }
        return true
    }
}

extension MeetingRowModel {
    /// Why a recording did not finish, in the daemon's words with the terminal talk left out; nil when there is none
    /// to give or the recording is fine.
    public static func failureReason(of info: MeetingInfo) -> String? {
        guard info.status == .failed || info.status == .transcribed, let error = info.error else { return nil }
        let reason = PlainWords.clean(error, fallback: "")
        return reason.isEmpty ? nil : reason
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
