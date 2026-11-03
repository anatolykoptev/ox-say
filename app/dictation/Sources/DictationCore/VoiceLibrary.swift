import Foundation

/// One voice in the library, as the daemon's `GET /v1/audio/voices` reports
/// it. `label` is what the person reads; `id` is the daemon's file-safe name.
public struct VoiceEntry: Equatable, Identifiable {
    /// Where the voice's audio came from.
    public enum Kind: Equatable {
        /// Rendered from a written description (`designed_from` is the description).
        case designed(String)
        /// Recorded for the voice.
        case recorded
        /// Picked from an audio file.
        case file
        /// Added before the daemon said where (or another way entirely).
        case other
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var created: Date?
    /// The voice's preferred TTS model; nil = the daemon default.
    public var engine: String?

    public init(id: String, label: String, kind: Kind, created: Date? = nil, engine: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.created = created
        self.engine = engine
    }

    /// `created`, unless it is absent or Go's zero time (year 1: what a Time with
    /// no value marshals as). Such a date says nothing, so no line shows it.
    var knownCreated: Date? {
        guard let created else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.component(.year, from: created) <= 1 ? nil : created
    }

    /// The line under the voice's name: how it came to be, with its date when
    /// the daemon gave a real one. With none (absent, or Go's zero time) the
    /// line carries no date at all rather than today's or "1 January".
    public func subtitle(locale: Locale, calendar: Calendar,
                         text: (L10nKey) -> String = { $0.text }) -> String {
        switch kind {
        case .designed: return text(.voicesSubtitleDesigned)
        case .file: return text(.voicesSubtitleFile)
        case .recorded:
            guard let date = knownCreated else { return text(.voicesSubtitleRecordedUndated) }
            return String(format: text(.voicesSubtitleRecorded), Self.day(date, locale: locale, calendar: calendar))
        case .other:
            guard let date = knownCreated else { return text(.voicesSubtitleOtherUndated) }
            return String(format: text(.voicesSubtitleOther), Self.day(date, locale: locale, calendar: calendar))
        }
    }

    /// "28 октября" / "October 28" — the day the voice was kept.
    private static func day(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return formatter.string(from: date)
    }

    /// `{"voices":[…]}`. With no voices the daemon writes `{"voices":null}` (a nil
    /// Go slice), and an older or terse one may omit the key: both are an empty
    /// library, `[]`. Any other type is nil, a read that failed. An entry without a label shows its id (a daemon older
    /// than labels writes none); one without a source or a designed_from is
    /// `.other`. Entries that do not parse are skipped, as in MeetingInfo.
    public static func decodeList(_ data: Data) -> [VoiceEntry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch obj["voices"] {
        case nil, is NSNull: return []
        case let list as [[String: Any]]: return list.compactMap(decode)
        default: return nil
        }
    }

    static func decode(_ obj: [String: Any]) -> VoiceEntry? {
        guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
        let kind: Kind
        if let description = nonEmpty(obj["designed_from"]) {
            kind = .designed(description)
        } else {
            switch nonEmpty(obj["source"]) {
            case "recorded": kind = .recorded
            case "file": kind = .file
            default: kind = .other
            }
        }
        return VoiceEntry(id: name,
                          label: nonEmpty(obj["label"]) ?? name,
                          kind: kind,
                          created: daemonDate(obj["created"]),
                          engine: nonEmpty(obj["engine"]))
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        (raw as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Go's time.Time marshals with fractional seconds whenever it has nanos,
    /// which a default ISO8601DateFormatter refuses (MeetingModels.swift does
    /// the same two-step for `started`).
    static func daemonDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return iso.date(from: s) ?? plain.date(from: s)
    }
}

extension Array where Element == VoiceEntry {
    /// What a picker shows for a voice id: the entry's label, or the id itself when the id names no entry or the
    /// entry's label is empty (the stored pick and the row's tag keep the id either way).
    public func title(for id: String) -> String {
        guard let label = first(where: { $0.id == id })?.label, !label.isEmpty else { return id }
        return label
    }
}
