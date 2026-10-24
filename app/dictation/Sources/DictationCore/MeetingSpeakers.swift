import Foundation

/// One of the far side's speakers, as the daemon lists them
/// (`GET /v1/meetings/{id}/speakers`): a voice ("them:2"), or the single
/// far-side label ("them") when the transcript has no voices.
public struct SpeakerInfo: Equatable {
    public var id: String
    /// The name the user gave, "" until then.
    public var name: String
    /// What the transcript prints for this speaker now.
    public var label: String
    public var speechSeconds: Double
    /// The start of the speaker's longest turn: how the user tells the voices apart.
    public var sample: String
    /// Set when the voice was folded into another one.
    public var mergedTo: String?

    public init(id: String, name: String = "", label: String, speechSeconds: Double = 0, sample: String = "", mergedTo: String? = nil) {
        self.id = id
        self.name = name
        self.label = label
        self.speechSeconds = speechSeconds
        self.sample = sample
        self.mergedTo = mergedTo
    }

    public var isVoice: Bool { id.hasPrefix("them:") }
}

/// The speakers of one meeting and what the user can do with them.
public struct SpeakersState: Equatable {
    /// "auto" (three or more voices, shown), "offer" (two voices, one label until the split) or "".
    public var mode: String
    /// The offered voices are shown.
    public var split: Bool
    public var speakers: [SpeakerInfo]

    public init(mode: String = "", split: Bool = false, speakers: [SpeakerInfo] = []) {
        self.mode = mode
        self.split = split
        self.speakers = speakers
    }

    /// Two voices were found and the transcript still has one far-side label: "split by voice" is on offer.
    public var offersSplit: Bool { mode == "offer" && !split }

    /// Voices that are shown and not folded into another.
    public var liveVoices: [SpeakerInfo] { speakers.filter { $0.isVoice && $0.mergedTo == nil } }

    public static func decode(_ data: Data) -> SpeakersState? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (obj["speakers"] as? [[String: Any]] ?? []).compactMap { s -> SpeakerInfo? in
            guard let id = s["id"] as? String, !id.isEmpty else { return nil }
            let merged = s["merged_to"] as? String
            return SpeakerInfo(id: id, name: s["name"] as? String ?? "", label: s["label"] as? String ?? id,
                               speechSeconds: s["speech_s"] as? Double ?? 0, sample: s["sample"] as? String ?? "",
                               mergedTo: (merged?.isEmpty ?? true) ? nil : merged)
        }
        return SpeakersState(mode: obj["mode"] as? String ?? "", split: obj["split"] as? Bool ?? false, speakers: list)
    }
}

/// The body of `PATCH /v1/meetings/{id}/speakers`: only what changed.
public struct SpeakerEdits: Equatable {
    public var rename: [String: String] = [:]
    public var merge: [String: String] = [:]
    public var unmerge: [String] = []
    public var split: Bool?

    public init() {}

    public var isEmpty: Bool { rename.isEmpty && merge.isEmpty && unmerge.isEmpty && split == nil }

    /// A merge, an unmerge or the split changes who said what, so the daemon writes the notes again (minutes). A
    /// rename alone is corrected in the notes at once, and the exported copy can be refreshed right away.
    public var rewritesNotes: Bool { !merge.isEmpty || !unmerge.isEmpty || split != nil }

    public func body() -> Data {
        var obj: [String: Any] = [:]
        if !rename.isEmpty { obj["rename"] = rename }
        if !merge.isEmpty { obj["merge"] = merge }
        if !unmerge.isEmpty { obj["unmerge"] = unmerge.sorted() }
        if let split { obj["split"] = split }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// What the Speakers panel edits before it sends anything: the names in the
/// text fields, the "same person as" picks and the split switch. Kept apart
/// from AppKit so the diff against the daemon's state is tested.
public struct SpeakerDraft: Equatable {
    public var names: [String: String]
    public var mergeInto: [String: String]
    public var split: Bool

    public init(from state: SpeakersState) {
        names = Dictionary(uniqueKeysWithValues: state.speakers.map { ($0.id, $0.name) })
        mergeInto = Dictionary(uniqueKeysWithValues: state.speakers.compactMap { s in s.mergedTo.map { (s.id, $0) } })
        split = state.split
    }

    /// The request that takes `state` to this draft. A name only counts when it
    /// differs after trimming; an emptied field clears the name.
    public func edits(against state: SpeakersState) -> SpeakerEdits {
        var e = SpeakerEdits()
        for s in state.speakers {
            let now = (names[s.id] ?? s.name).trimmingCharacters(in: .whitespacesAndNewlines)
            if now != s.name.trimmingCharacters(in: .whitespacesAndNewlines) { e.rename[s.id] = now }
            switch (s.mergedTo, mergeInto[s.id]) {
            case let (old?, new?) where old != new: e.unmerge.append(s.id); e.merge[s.id] = new
            case (nil, let new?): e.merge[s.id] = new
            case (_?, nil): e.unmerge.append(s.id)
            default: break
            }
        }
        if split != state.split { e.split = split }
        return e
    }

    /// The voices `id` may be folded into: the other voices that are still
    /// standing in this draft and have nothing folded into `id` (no chains).
    public func mergeTargets(for id: String, in state: SpeakersState) -> [SpeakerInfo] {
        guard !mergeInto.values.contains(id) else { return [] }
        return state.speakers.filter { $0.isVoice && $0.id != id && mergeInto[$0.id] == nil }
    }
}

/// The Recent Meetings rows of the Meetings submenu: meetings whose speakers can be named.
public struct MeetingMenuRecent: Equatable {
    public var id: String
    public var title: String
    public var started: Date?
    /// Set when the voices could not be told apart: the row says why instead of offering the names.
    public var problem: DiarProblem?

    public init(id: String, title: String, started: Date? = nil, problem: DiarProblem? = nil) {
        self.id = id
        self.title = title
        self.started = started
        self.problem = problem
    }

    /// The newest meetings with a transcript that have something to say about their speakers: voices to name, or a
    /// problem. A problem that is the Mac's own (`unavailable`) is said once, for the newest meeting: it is the same
    /// for all of them and would fill the menu.
    public static func from(_ meetings: [MeetingInfo], limit: Int = 3) -> [MeetingMenuRecent] {
        var rows: [MeetingMenuRecent] = []
        var saidUnavailable = false
        for m in meetings where m.status == .done || m.status == .transcribed {
            let problem = m.diarProblem
            let hasVoices = m.voiceMode == "auto" || m.voiceMode == "offer"
            if case .unavailable? = problem {
                if saidUnavailable { continue }
                saidUnavailable = true
            } else if problem == nil && !hasVoices {
                continue
            }
            rows.append(MeetingMenuRecent(id: m.id, title: m.title, started: m.started, problem: problem))
            if rows.count == limit { break }
        }
        return rows
    }
}
