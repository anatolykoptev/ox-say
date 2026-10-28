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
    /// Only meaningful on the answer to an edit: the daemon queued the notes to be written again, so they are not
    /// final yet (a merge, an unmerge, the split, or a rename it could not substitute safely). False: the notes are
    /// final now and the exported copy can be refreshed at once. The app follows this, never the kind of edit it sent.
    public var notesQueued: Bool

    public init(mode: String = "", split: Bool = false, speakers: [SpeakerInfo] = [], notesQueued: Bool = false) {
        self.mode = mode
        self.split = split
        self.speakers = speakers
        self.notesQueued = notesQueued
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
        return SpeakersState(mode: obj["mode"] as? String ?? "", split: obj["split"] as? Bool ?? false, speakers: list,
                             notesQueued: obj["notes_queued"] as? Bool ?? false)
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
    /// differs after trimming; an emptied field clears the name. A voice folded into another loses its name in the
    /// daemon, so a name typed on it goes to the voice it joins when that one has none. Picks that the daemon would
    /// refuse (a loop, or a chain through a voice that is itself folded away) are left out, see `standingMerges`.
    public func edits(against state: SpeakersState) -> SpeakerEdits {
        var e = SpeakerEdits()
        let merges = standingMerges(against: state)
        var folded: [(from: String, into: String, name: String)] = []
        for s in state.speakers {
            let typed = (names[s.id] ?? s.name).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = merges[s.id]
            let newlyFolded = target != nil && target != s.mergedTo
            if !newlyFolded, typed != s.name.trimmingCharacters(in: .whitespacesAndNewlines) { e.rename[s.id] = typed }
            switch (s.mergedTo, target) {
            case let (old?, new?) where old != new: e.unmerge.append(s.id); e.merge[s.id] = new
            case (nil, let new?): e.merge[s.id] = new
            case (_?, nil): e.unmerge.append(s.id)
            default: break
            }
            if newlyFolded, let target, !typed.isEmpty { folded.append((s.id, target, typed)) }
        }
        for f in folded.sorted(by: { $0.from < $1.from }) {
            let own = state.speakers.first(where: { $0.id == f.into })?.name ?? ""
            let current = (e.rename[f.into] ?? names[f.into] ?? own).trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty { e.rename[f.into] = f.name }
        }
        if split != state.split { e.split = split }
        return e
    }

    /// The picks of this draft that can all stand together: every target is a voice that is not itself folded away,
    /// and nothing folded into a voice follows it elsewhere (no loops, no chains). The merges the meeting already has
    /// come first, so a new pick never undoes one; among new picks the lower id wins. A pick that is left out shows
    /// as "—" the next time the panel opens; the names typed beside it are still saved.
    private func standingMerges(against state: SpeakersState) -> [String: String] {
        var kept: [String: String] = [:]
        func accept(_ from: String, _ into: String) {
            guard from != into, kept[into] == nil, !kept.values.contains(from) else { return }
            kept[from] = into
        }
        let ids = state.speakers.map(\.id).sorted()
        let held = Dictionary(uniqueKeysWithValues: state.speakers.compactMap { s in s.mergedTo.map { (s.id, $0) } })
        for id in ids { if let into = mergeInto[id], held[id] == into { accept(id, into) } }
        for id in ids {
            guard let into = mergeInto[id], held[id] != into else { continue }
            accept(id, into)
            // A refused new pick leaves the merge the user already has; only an explicit "—" (no pick) splits it.
            if kept[id] == nil, let old = held[id] { accept(id, old) }
        }
        return kept
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
    /// Retention removed the recording: a retry would transcribe nothing, so the row offers none.
    public var audioGone: Bool
    /// The daemon says a voices retry would be accepted now (`MeetingInfo.voicesRetryable`); only an unavailable problem reads it.
    public var voicesRetryable: Bool

    public init(id: String, title: String, started: Date? = nil, problem: DiarProblem? = nil, audioGone: Bool = false,
                voicesRetryable: Bool = false) {
        self.id = id
        self.title = title
        self.started = started
        self.problem = problem
        self.audioGone = audioGone
        self.voicesRetryable = voicesRetryable
    }

    /// The newest meetings with a transcript that have something to say about their speakers: voices to name, or a
    /// problem. A problem that is the Mac's own (`unavailable`) is said once per reason, for the newest meeting that has
    /// it: it is the same for all of them and would fill the menu. `too_long` is about one recording, not the Mac, so
    /// it is said for each.
    public static func from(_ meetings: [MeetingInfo], limit: Int = 3) -> [MeetingMenuRecent] {
        var rows: [MeetingMenuRecent] = []
        var saidReasons: Set<String> = []
        for m in meetings where m.status == .done || m.status == .transcribed {
            let problem = m.diarProblem
            let hasVoices = m.voiceMode == "auto" || m.voiceMode == "offer"
            if case .unavailable(let reason)? = problem {
                // A Mac-wide reason is said once, but a meeting that can be retried keeps its own row: the retry is for it.
                if reason != "too_long", !m.offersVoicesRetry, !saidReasons.insert(reason).inserted { continue }
            } else if problem == nil && !hasVoices {
                continue
            }
            rows.append(MeetingMenuRecent(id: m.id, title: m.title, started: m.started, problem: problem, audioGone: m.audioDeleted,
                                         voicesRetryable: m.voicesRetryable))
            if rows.count == limit { break }
        }
        return rows
    }
}
