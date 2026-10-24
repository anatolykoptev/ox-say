import Foundation

/// What the recording badge shows, as plain values; AppKit only draws them.
public enum MeetingBadgeModel {
    /// "REC 12:34" (or "REC 1:02:03" from one hour).
    public static func recText(elapsed: TimeInterval, format: String) -> String {
        String(format: format, clock(elapsed))
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let n = max(0, Int(seconds))
        if n >= 3600 { return String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) }
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    /// The consent reminder and its copy button show for this long after a recording starts.
    public static let consentHintSeconds: TimeInterval = 20

    public static func showsConsentHint(elapsed: TimeInterval) -> Bool { elapsed < consentHintSeconds }
}

/// Everything the Meetings submenu needs to decide its rows.
public struct MeetingMenuState: Equatable {
    public var supported: Bool
    public var recordingElapsed: TimeInterval?
    public var notes: NotesStatus
    public var autoStart: Bool
    public var retention: MeetingRetention
    /// Meetings whose speakers can be named, newest first.
    public var recent: [MeetingMenuRecent]

    public init(supported: Bool, recordingElapsed: TimeInterval?, notes: NotesStatus, autoStart: Bool, retention: MeetingRetention,
                recent: [MeetingMenuRecent] = []) {
        self.supported = supported
        self.recordingElapsed = recordingElapsed
        self.notes = notes
        self.autoStart = autoStart
        self.retention = retention
        self.recent = recent
    }
}

public enum MeetingMenu {
    private static func unavailableKey(_ reasonCode: String?) -> L10nKey? {
        switch reasonCode {
        case "engine_missing": return .menuMeetingNotesNeedUpdate
        case "unsupported": return .menuMeetingNotesUnsupported
        default: return nil
        }
    }

    /// The rows of the Meetings submenu. `text` resolves a localization key
    /// (the app passes `L10nKey.text`; tests pass the raw key).
    public static func rows(_ s: MeetingMenuState, text: (L10nKey) -> String) -> [MenuRow] {
        var rows: [MenuRow] = []
        if !s.supported {
            return [.item(title: text(.menuMeetingNeedsNewerMacOS), isOn: false, isEnabled: false, action: nil)]
        }
        if let elapsed = s.recordingElapsed {
            rows.append(.item(title: String(format: text(.menuMeetingStop), MeetingBadgeModel.clock(elapsed)),
                              isOn: false, isEnabled: true, action: .stopMeeting))
        } else {
            rows.append(.item(title: text(.menuMeetingRecord), isOn: false, isEnabled: true, action: .startMeeting))
        }
        rows.append(.separator)
        if s.notes.installing {
            rows.append(.item(title: String(format: text(.menuMeetingDownloading), "\(s.notes.progressPercent)%"),
                              isOn: false, isEnabled: false, action: nil))
        } else {
            // Why the notes are not there, when the user can read it: a failed
            // download says so (and the Download row below retries); a Mac or an
            // install that cannot make notes says so instead of showing nothing.
            if let error = s.notes.installError {
                rows.append(.item(title: String(format: text(.menuMeetingInstallFailed), error),
                                  isOn: false, isEnabled: false, action: nil))
            }
            if s.notes.downloadWouldHelp {
                rows.append(.item(title: text(.menuMeetingInstallModel), isOn: false, isEnabled: true, action: .installNotesModel))
            } else if !s.notes.available, let why = unavailableKey(s.notes.reasonCode) {
                rows.append(.item(title: text(why), isOn: false, isEnabled: false, action: nil))
            }
        }
        rows.append(.item(title: text(.menuMeetingOpenFolder), isOn: false, isEnabled: true, action: .openMeetingsFolder))
        rows.append(.item(title: text(.menuMeetingChooseFolder), isOn: false, isEnabled: true, action: .chooseMeetingsFolder))
        rows.append(.item(title: text(.menuMeetingYourName), isOn: false, isEnabled: true, action: .setMeetingName))
        if !s.recent.isEmpty {
            rows.append(.separator)
            rows.append(.header(text(.menuMeetingSpeakers)))
            for r in s.recent {
                let name = r.title.isEmpty ? recentDate(r.started) : r.title
                guard let problem = r.problem else {
                    rows.append(.item(title: String(format: text(.menuMeetingSpeakersItem), name),
                                      isOn: false, isEnabled: true, action: .editSpeakers(r.id)))
                    continue
                }
                rows.append(.item(title: text(problem.messageKey), isOn: false, isEnabled: false, action: nil))
                if problem.canRetry, !r.audioGone {
                    rows.append(.item(title: String(format: text(.menuMeetingSpeakersRetry), name),
                                      isOn: false, isEnabled: true, action: .retryVoices(r.id)))
                }
            }
        }
        rows.append(.separator)
        rows.append(.item(title: text(.menuMeetingAutoStart), isOn: s.autoStart, isEnabled: true, action: .toggleMeetingAutoStart))
        rows.append(.header(text(.menuMeetingKeep)))
        for r in MeetingRetention.allCases {
            rows.append(.item(title: text(r.titleKey), isOn: r == s.retention, isEnabled: true, action: .pickMeetingRetention(r.days)))
        }
        return rows
    }

    private static func recentDate(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
