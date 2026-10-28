import Foundation

/// How a delete ended.
public enum DeleteOutcome: Equatable {
    case done
    /// The daemon no longer has it: the list is refreshed, nobody is told off.
    case alreadyGone
    /// The sentence for the user; the meeting is still there.
    case failed(String)
}

/// The window's reads and deletes against the daemon, turned into what the page needs: the list or a sentence, a
/// detail with its speakers, an outcome. Everything a user might see go wrong has a sentence here.
public struct MeetingWindowService {
    public var client: StudioClient

    public init(client: StudioClient) { self.client = client }

    public func delete(id: String, text: (L10nKey) -> String = { $0.text }) async -> DeleteOutcome {
        do {
            try await client.deleteMeeting(id: id)
            return .done
        } catch {
            if MeetingErrorText.isAlreadyGone(error, action: .delete) { return .alreadyGone }
            return .failed(MeetingErrorText.sentence(error, action: .delete, text: text))
        }
    }

    /// The meetings, newest first, or nil with the reason: a failed read leaves what the caller shows as it is.
    public func list(text: (L10nKey) -> String = { $0.text }) async -> (meetings: [MeetingInfo]?, load: MeetingsLoad) {
        do {
            return (try await client.meetings(), .loaded)
        } catch {
            return (nil, .failed(MeetingErrorText.sentence(error, action: .refresh, text: text)))
        }
    }

    /// One meeting with its notes and transcript, and its speakers once there is a transcript to attribute. The speakers
    /// failing is the Speakers tab's problem, not the notes'.
    public func detail(id: String, text: (L10nKey) -> String = { $0.text }) async -> Result<MeetingDetail, MeetingWindowFailure> {
        let info: MeetingInfo
        do {
            info = try await client.meeting(id: id, withTexts: true)
        } catch {
            return .failure(MeetingWindowFailure(MeetingErrorText.sentence(error, action: .refresh, text: text)))
        }
        guard info.status == .done || info.status == .transcribed else { return .success(MeetingDetail(info: info)) }
        do {
            return .success(MeetingDetail(info: info, speakers: try await client.speakers(id: id)))
        } catch {
            return .success(MeetingDetail(info: info, speakers: nil,
                                          speakersError: MeetingErrorText.sentence(error, action: .speakers, text: text)))
        }
    }
}

/// A failure with its sentence (a `String` cannot be the `Failure` of a `Result`).
public struct MeetingWindowFailure: Error, Equatable {
    public var sentence: String
    public init(_ sentence: String) { self.sentence = sentence }
}

/// One meeting as the detail pane needs it: the daemon's meeting (with the texts) and its speakers.
public struct MeetingDetail: Equatable {
    public var info: MeetingInfo
    /// nil until the speakers were read, or when they could not be.
    public var speakers: SpeakersState?
    /// Why the speakers could not be read.
    public var speakersError: String?

    public init(info: MeetingInfo, speakers: SpeakersState? = nil, speakersError: String? = nil) {
        self.info = info
        self.speakers = speakers
        self.speakersError = speakersError
    }
}

extension NotesWriterState {
    /// The Settings row for the daemon's notes engine; nil is a daemon that could not be asked.
    public static func of(_ status: NotesStatus?) -> NotesWriterState {
        guard let status else { return .unavailable(.meetingErrDaemonDown) }
        if status.available { return status.reasonCode == "notes_engine_failed" ? .engineFailed(.settingsNotesWriterEngineFailed) : .ready }
        if status.installing { return .downloading(percent: status.progressPercent) }
        if status.reasonCode == "model_missing" {
            return status.installError == nil ? .missing : .downloadFailed(downloadFailureKey(status.installErrorCode))
        }
        if status.reasonCode == "unsupported" { return .unavailable(.menuMeetingNotesUnsupported) }
        return .unavailable(.menuMeetingNotesNeedUpdate)
    }

    /// The sentence for a failed download; a code this app does not know (or none) gets the general one.
    static func downloadFailureKey(_ code: String?) -> L10nKey {
        switch code {
        case "network": return .settingsNotesWriterDownloadNetwork
        case "disk_full": return .settingsNotesWriterDownloadDisk
        case "checksum": return .settingsNotesWriterDownloadChecksum
        case "server": return .settingsNotesWriterDownloadServer
        default: return .settingsNotesWriterDownloadOther
        }
    }

    /// The short sentence for the same failure in the menu (a menu row stays one short line).
    static func menuDownloadFailureKey(_ code: String?) -> L10nKey {
        switch code {
        case "network": return .menuMeetingInstallFailedNetwork
        case "disk_full": return .menuMeetingInstallFailedDisk
        case "checksum": return .menuMeetingInstallFailedChecksum
        case "server": return .menuMeetingInstallFailedServer
        default: return .menuMeetingInstallFailedOther
        }
    }
}
