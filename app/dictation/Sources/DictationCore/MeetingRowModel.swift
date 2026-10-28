import Foundation

/// What a meeting's status says in plain words, and whether work is still going
/// on behind it (a spinner). The daemon's `Status` has seven cases and a pending
/// reason; the window shows these seven lines.
public enum MeetingStatusLine: Equatable, CaseIterable {
    case recording
    case waiting
    case transcribing
    case writingNotes
    case ready
    /// The transcript is there and the notes are not: the notes writer is missing or its run failed.
    case transcriptOnly
    case failed
    /// A status a newer daemon added, on a meeting too old to still be running: shown plainly, nothing spins.
    case unrecognized

    public var titleKey: L10nKey {
        switch self {
        case .recording: return .meetingsStatusRecording
        case .waiting: return .meetingsStatusWaiting
        case .transcribing: return .meetingsStatusTranscribing
        case .writingNotes: return .meetingsStatusNotes
        case .ready: return .meetingsStatusReady
        case .transcriptOnly: return .meetingsStatusTranscriptOnly
        case .failed: return .meetingsStatusFailed
        case .unrecognized: return .meetingsStatusUnrecognized
        }
    }

    /// Work is still running: the row shows a spinner and the window keeps checking.
    public var isBusy: Bool {
        switch self {
        case .recording, .waiting, .transcribing, .writingNotes: return true
        case .ready, .transcriptOnly, .failed, .unrecognized: return false
        }
    }
}

/// How the Meetings list and a meeting's header write a `MeetingInfo`: status,
/// title, length, day groups. Pure; every text takes the resolver and the locale.
public enum MeetingRowModel {
    public static func status(of info: MeetingInfo, now: Date = Date()) -> MeetingStatusLine {
        switch info.status {
        case .recording: return .recording
        case .queued: return .waiting
        case .transcribing: return .transcribing
        case .summarizing: return .writingNotes
        case .done: return .ready
        case .failed: return .failed
        case .transcribed: return .transcriptOnly
        // A status this app does not know is work it cannot see the end of: while the meeting is recent the row says
        // "waiting", keeps its spinner and the window keeps checking, and settled stays false so nothing is offered
        // on it. An old one stops there (MeetingInfo.inProgress): a neutral line, no spinner, no polling.
        case .unknown: return info.inProgress(now: now) ? .waiting : .unrecognized
        }
    }

    /// The title the user named, else "Call".
    public static func title(of info: MeetingInfo, text: (L10nKey) -> String = { $0.text }) -> String {
        let t = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? text(.meetingsUntitled) : t
    }

    /// "42 min", "1 h 5 min", "under a minute"; nil while the length is not known.
    public static func duration(_ seconds: Double?, text: (L10nKey) -> String = { $0.text }) -> String? {
        guard let seconds else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return text(.meetingDurationSec) }
        if minutes < 60 { return String(format: text(.meetingDurationMin), minutes) }
        return String(format: text(.meetingDurationHourMin), minutes / 60, minutes % 60)
    }

    public static func time(_ date: Date, locale: Locale = L10nBundle.locale, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// One day's recordings under their heading ("Today", "Yesterday", "23 October").
    public struct DayGroup: Equatable {
        public var title: String
        public var meetings: [MeetingInfo]
    }

    /// The list grouped by the day each meeting started, in the order given (newest first).
    /// A meeting with no start date goes last under no heading.
    public static func groups(_ meetings: [MeetingInfo], now: Date = Date(), locale: Locale = L10nBundle.locale,
                              calendar: Calendar = .current, text: (L10nKey) -> String = { $0.text }) -> [DayGroup] {
        var out: [DayGroup] = []
        var dayOfLast: Date?
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        for m in meetings {
            guard let started = m.started else {
                if out.last?.title == "" { out[out.count - 1].meetings.append(m) } else { out.append(DayGroup(title: "", meetings: [m])) }
                continue
            }
            let day = calendar.startOfDay(for: started)
            if let dayOfLast, dayOfLast == day, !out.isEmpty {
                out[out.count - 1].meetings.append(m)
                continue
            }
            dayOfLast = day
            let title: String
            if calendar.isDate(started, inSameDayAs: now) {
                title = text(.meetingsToday)
            } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(started, inSameDayAs: y) {
                title = text(.meetingsYesterday)
            } else {
                let sameYear = calendar.component(.year, from: started) == calendar.component(.year, from: now)
                f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMMM" : "dMMMMy")
                title = f.string(from: started)
            }
            out.append(DayGroup(title: title, meetings: [m]))
        }
        return out
    }
}

/// A meeting's notes (the daemon's notes.md) as blocks the window can lay out
/// without a Markdown engine: sections, bullets, action items with who/what/when.
public struct NotesDocument: Equatable {
    public enum Item: Equatable {
        case paragraph(String)
        case bullet(String)
        case action(who: String, what: String, when: String)
    }

    public struct Section: Equatable {
        public var title: String
        public var items: [Item]
    }

    public var sections: [Section]

    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    /// Reads notes.md as `NotesMarkdown` writes it: "# Title", then "## Heading" sections of
    /// paragraphs, "- bullet" lines and "- [ ] who — what — when" action lines. The title line is
    /// dropped (the window shows the title itself). Anything unrecognised is kept as a paragraph.
    public static func parse(_ markdown: String) -> NotesDocument {
        var sections: [Section] = []
        var current = Section(title: "", items: [])
        func flush() { if !current.title.isEmpty || !current.items.isEmpty { sections.append(current) } }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("## ") {
                flush()
                current = Section(title: String(line.dropFirst(3)), items: [])
            } else if line.hasPrefix("# ") {
                continue
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                let body = String(line.dropFirst(6))
                let parts = body.components(separatedBy: " — ")
                if parts.count == 3 {
                    current.items.append(.action(who: TranscriptTurn.unescaped(parts[0], extra: "#!"), what: parts[1], when: TranscriptTurn.unescaped(parts[2], extra: "#!")))
                } else {
                    current.items.append(.action(who: "", what: body, when: ""))
                }
            } else if line.hasPrefix("- ") {
                current.items.append(.bullet(String(line.dropFirst(2))))
            } else {
                current.items.append(.paragraph(line))
            }
        }
        flush()
        return NotesDocument(sections: sections)
    }
}

/// One turn of the transcript: who spoke, when, and what. `speaker` is the name as the user typed it: transcript.md
/// writes it with a backslash before each markup character, and parsing takes them out again.
public struct TranscriptTurn: Equatable, Identifiable {
    public var id: Int
    public var speaker: String
    public var time: String
    public var text: String

    /// Reads transcript.md as `TranscriptMarkdown` writes it: one "**Name** [m:ss]: text" paragraph per turn.
    public static func parse(_ markdown: String) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for line in markdown.components(separatedBy: .newlines) {
            guard line.hasPrefix("**"), let close = line.range(of: "** [") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            let rest = line[close.upperBound...]
            guard let end = rest.range(of: "]: ") else { continue }
            turns.append(TranscriptTurn(id: turns.count, speaker: unescaped(name), time: String(rest[..<end.lowerBound]),
                                        text: unescaped(String(rest[end.upperBound...]))))
        }
        return turns
    }

    /// `\*` is `*`: a backslash before one of the characters the daemon escapes (`escapeMarkdown`) is dropped, so `\\`
    /// is `\`. `extra` adds the characters the notes writer also escapes at the start of a model line (`#`, `!`).
    static func unescaped(_ name: String, extra: String = "") -> String {
        guard name.contains("\\") else { return name }
        let specials = Set("\\`*_[]<>&" + extra)
        var out = ""
        var escaping = false
        for ch in name {
            if escaping {
                if !specials.contains(ch) { out.append("\\") }
                out.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
}

extension MeetingRowModel {
    /// What a rename sends: the draft trimmed, or nil when there is nothing to send. The field starts with the title the
    /// window SHOWS (an auto title is localized there), so a draft the user did not change must not become their own
    /// title, in whatever language the window happened to be in (#270). An empty draft is no title.
    public static func renamedTitle(draft: String, shown: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != shown.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return t
    }
}
