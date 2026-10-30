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
            let stored = MeetingLimits.clamp(s.name, to: MeetingLimits.nameMax)
            let typed = Self.sendable(names[s.id] ?? s.name, stored: stored)
            let target = merges[s.id]
            let newlyFolded = target != nil && target != s.mergedTo
            if !newlyFolded, typed != stored { e.rename[s.id] = typed }
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
            let current = Self.sendable(e.rename[f.into] ?? names[f.into] ?? own, stored: MeetingLimits.clamp(own, to: MeetingLimits.nameMax))
            if current.isEmpty { e.rename[f.into] = f.name }
        }
        if split != state.split { e.split = split }
        return e
    }

    /// The name to send for `raw`: cleaned the way the daemon requires and cut to the cap. A name the daemon would
    /// refuse and that cannot be repaired, or one that the cut would empty (one huge Character), is not sent: the
    /// stored name stays. "" (an emptied field) is a real edit and clears the name.
    private static func sendable(_ raw: String, stored: String) -> String {
        let cleaned = MeetingLimits.speakerName(raw)
        let typed = MeetingLimits.clamp(cleaned, to: MeetingLimits.nameMax)
        if typed.isEmpty { return cleaned.isEmpty ? "" : stored }
        return MeetingLimits.hasLetterOrDigit(typed) ? typed : stored
    }

    /// The voices whose typed name the daemon refuses and which cannot be repaired by dropping characters: no letter
    /// or digit in it. A voice that is being folded into another in this draft is left out: `edits` never sends its
    /// name (it goes to the voice it joins, or nowhere), so a leftover there blocks nothing.
    public func refusedSpeakers(against state: SpeakersState) -> [SpeakerInfo] {
        let merges = standingMerges(against: state)
        return state.speakers.filter { s in
            let newlyFolded = merges[s.id] != nil && merges[s.id] != s.mergedTo
            if newlyFolded { return false }
            let typed = MeetingLimits.clamp(MeetingLimits.speakerName(names[s.id] ?? s.name), to: MeetingLimits.nameMax)
            return !typed.isEmpty && !MeetingLimits.hasLetterOrDigit(typed)
        }
    }

    /// The sentence to show instead of saving (the main window disables Save on it): a typed name that holds no letter
    /// or digit. nil when every name can be sent.
    public func refusal(against state: SpeakersState) -> L10nKey? {
        refusedSpeakers(against: state).isEmpty ? nil : .speakersNameNeedsLetter
    }

    /// What the menu's panel does on OK: sends the renames and merges that are fine and names the voices whose name
    /// it refused, instead of dropping the whole save for one of them.
    /// `owner`: the meeting's own label for the person who recorded it (`MeetingInfo.ownerLabel`); the daemon counts
    /// the owner as a speaker too. nil when it is not known: that name is then left to the daemon.
    public func savePlan(against state: SpeakersState, owner: String? = nil) -> SpeakersSavePlan {
        var e = edits(against: state)
        let duplicates = dropDuplicates(from: &e, against: state, owner: owner)
        return SpeakersSavePlan(edits: e, refused: refusedSpeakers(against: state), duplicates: duplicates)
    }

    /// What the main window's Save button and its line under the speakers do. The window does not send a part of a draft
    /// (that is the menu's way): while a typed name is refused or already taken, `edits` is nil (Save is disabled) and
    /// `line` names the voices and the reason, so a draft that the daemon would answer with a 400 is never sent.
    public struct WindowSave: Equatable {
        public var line: String?
        public var edits: SpeakerEdits?
    }

    public func windowSave(against state: SpeakersState, owner: String? = nil,
                           text: (L10nKey) -> String = { $0.text }) -> WindowSave {
        let plan = savePlan(against: state, owner: owner)
        let line = plan.notSavedSentence(text: text)
        return WindowSave(line: line, edits: (line != nil || plan.edits.isEmpty) ? nil : plan.edits)
    }

    /// How the daemon reads a name when it compares two (`internal/meeting/speakers.go` checkDistinct):
    /// `strings.TrimSpace` + `strings.EqualFold`, i.e. trimmed and compared by Unicode simple case folding. Each scalar
    /// goes to upper case and back to lower case when both are single scalars (so the Greek final sigma and the long s
    /// meet their letter, and sharp s stays itself, as in Go).
    static func nameKey(_ name: String) -> String {
        func single(_ mapped: String, or scalar: Unicode.Scalar) -> Unicode.Scalar {
            let scalars = mapped.unicodeScalars
            return scalars.count == 1 ? scalars.first! : scalar
        }
        var out = String.UnicodeScalarView()
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            let upper = single(scalar.properties.uppercaseMapping, or: scalar)
            out.append(single(upper.properties.lowercaseMapping, or: upper))
        }
        return String(out)
    }

    /// Takes out of `e` the renames the daemon would 400 the whole save for: a name that, after the merges and the other
    /// renames of this draft, reads like another live speaker's (the daemon compares with `nameKey`). The lower id of
    /// two that collide keeps its name; a name equal to the owner's is a duplicate of the owner. A name that is cleared has no default label to compare, so it is not checked.
    /// Names with no letter or digit never reach `e` (they are `refusedSpeakers`), so one name is reported once.
    private func dropDuplicates(from e: inout SpeakerEdits, against state: SpeakersState, owner: String?) -> [SpeakerInfo] {
        let ownerKey = owner.map(Self.nameKey).flatMap { $0.isEmpty ? nil : $0 }
        let merges = standingMerges(against: state)
        let shownVoices = state.mode == "auto" || (state.mode == "offer" && split)
        let standing = state.speakers.filter { merges[$0.id] == nil && $0.isVoice == shownVoices }
        var dropped: [SpeakerInfo] = []
        while true {
            func label(_ s: SpeakerInfo) -> String? {
                guard let renamed = e.rename[s.id] else { return s.label }
                return renamed.isEmpty ? nil : renamed
            }
            let clashing = e.rename.keys.sorted().filter { id in
                guard let name = e.rename[id], !name.isEmpty else { return false }
                let own = merges[id] ?? id
                let key = Self.nameKey(name)
                if key == ownerKey { return true }
                return standing.contains { $0.id != own && label($0).map(Self.nameKey) == key }
            }
            guard let last = clashing.last else { return dropped.sorted { $0.id < $1.id } }
            e.rename[last] = nil
            if let info = state.speakers.first(where: { $0.id == last }) { dropped.append(info) }
        }
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

/// The menu panel's save: the edits to send, the voices whose typed name was refused (no letter or digit) and the ones
/// whose name another speaker already has. Neither is sent; the stored name stays.
public struct SpeakersSavePlan: Equatable {
    public var edits: SpeakerEdits
    public var refused: [SpeakerInfo]
    public var duplicates: [SpeakerInfo]

    public init(edits: SpeakerEdits, refused: [SpeakerInfo], duplicates: [SpeakerInfo] = []) {
        self.edits = edits
        self.refused = refused
        self.duplicates = duplicates
    }

    /// The sentence that names the refused voices (by what the transcript prints for them), nil when none was refused.
    public func refusedSentence(text: (L10nKey) -> String = { $0.text }) -> String? {
        guard !refused.isEmpty else { return nil }
        return String(format: text(.noticeSpeakersRefused), refused.map(\.label).joined(separator: ", "))
    }

    /// The sentence that names the voices whose name was taken by another speaker, nil when none was.
    public func duplicateSentence(text: (L10nKey) -> String = { $0.text }) -> String? {
        guard !duplicates.isEmpty else { return nil }
        return String(format: text(.noticeSpeakersDuplicate), duplicates.map(\.label).joined(separator: ", "))
    }

    /// Everything the save left out, as the one sentence that joins the save's notice; nil when it left nothing out.
    public func notSavedSentence(text: (L10nKey) -> String = { $0.text }) -> String? {
        let parts = [refusedSentence(text: text), duplicateSentence(text: text)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The menu panel's save with its side effects as closures, so that "exactly one notice per save" is a behaviour that
/// the tests drive with recording fakes instead of a pin on the app's source text.
public enum SpeakersSaveRun {
    /// Sends the plan's edits and says what happened in ONE notice. Nothing to send: the notice (if the plan left
    /// something out) is the refusal and nothing is sent; nil. Otherwise the daemon's answer.
    /// - `send`: the daemon call; its failure propagates and notifies nothing here (the caller says it once).
    /// - `followUp`: what the app does after a save (stale flag, notes, copy); returns the copy's sentence, if any.
    public static func run(plan: SpeakersSavePlan,
                           send: (SpeakerEdits) async throws -> SpeakersState,
                           followUp: (SpeakersState) async -> String?,
                           notify: (String) -> Void) async throws -> SpeakersState? {
        if plan.edits.isEmpty {
            if let sentence = plan.notSavedSentence() { notify(sentence) }
            return nil
        }
        return try await save(edits: plan.edits, notSaved: plan.notSavedSentence(), send: send, followUp: followUp, notify: notify)
    }

    /// The send and its single notice. `notSaved`: the plan's sentence for what was left out; it is appended to the
    /// notice, never a second one.
    public static func save(edits: SpeakerEdits, notSaved: String?,
                            send: (SpeakerEdits) async throws -> SpeakersState,
                            followUp: (SpeakersState) async -> String?,
                            notify: (String) -> Void) async throws -> SpeakersState {
        let state = try await send(edits)
        let exportSentence = await followUp(state)
        notify(SpeakersSaved.notice(refused: notSaved, notesQueued: state.notesQueued, exportSentence: exportSentence))
        return state
    }
}

/// What a menu save says and does once the daemon has answered: ONE notice per save (a second banner would bury the
/// first, and the status-line fallback keeps only the last sentence), and whether the panel opens again.
public enum SpeakersSaved {
    /// The save's single notice. `exportSentence`: what the notes-folder copy had to say (a copy left alone, a copy
    /// that could not be made) — it stands in for "names saved", which would bury it. `refused`: the plan's sentence
    /// for names that were not sent; it is appended, never a second notice.
    public static func notice(refused: String?, notesQueued: Bool, exportSentence: String?,
                              text: (L10nKey) -> String = { $0.text }) -> String {
        let base = notesQueued ? text(.noticeSpeakersSaved) : (exportSentence ?? text(.noticeSpeakersNamesSaved))
        guard let refused else { return base }
        return base + " " + refused
    }

    /// The split was on offer and the answer says it is taken: the panel opens again on the new state (the voices).
    public static func reopens(wasOffer: Bool, answer: SpeakersState) -> Bool { wasOffer && !answer.offersSplit }
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
    /// The daemon's word on whether a voices retry would be accepted now (`MeetingInfo.voicesRetryable`); nil when it said none.
    public var voicesRetryable: Bool?

    public init(id: String, title: String, started: Date? = nil, problem: DiarProblem? = nil, audioGone: Bool = false,
                voicesRetryable: Bool? = nil) {
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
