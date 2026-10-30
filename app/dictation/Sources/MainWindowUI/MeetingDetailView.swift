import DictationCore
import SwiftUI

public enum MeetingTab: String, CaseIterable, Identifiable {
    case notes, transcript, speakers
    public var id: String { rawValue }
    var titleKey: L10nKey {
        switch self {
        case .notes: return .meetingTabNotes
        case .transcript: return .meetingTabTranscript
        case .speakers: return .speakersTitle
        }
    }
}

extension MeetingTab {
    /// The tab a search hit opens.
    init(_ destination: HitDestination) {
        switch destination {
        case .notes: self = .notes
        case .transcript: self = .transcript
        }
    }
}

/// One recording: its title and facts, a notice when something needs saying, and three tabs.
/// The texts are parsed when the meeting is chosen; the transcript is a lazy stack, so a two-hour
/// call costs what is on screen.
struct MeetingDetailView: View {
    @ObservedObject var model: MainWindowModel
    let detail: MeetingDetail
    @State private var tab: MeetingTab
    @State private var renaming = false
    @State private var draftTitle = ""

    init(model: MainWindowModel, detail: MeetingDetail, tab: MeetingTab = .notes) {
        self.model = model
        self.detail = detail
        // A search hit that was clicked opens its meeting on the tab where it matched.
        if let focus = model.focus, focus.meetingID == detail.info.id {
            _tab = State(initialValue: MeetingTab(focus.destination))
        } else {
            _tab = State(initialValue: tab)
        }
    }

    private var info: MeetingInfo { detail.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(MeetingTab.allCases) { Text($0.titleKey.text).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24).padding(.bottom, 12)
            Divider()
            if let sentence = model.data.detailError[info.id] {
                Callout(symbol: "exclamationmark.triangle.fill", text: sentence) {
                    Button(L10nKey.commonRetry.text) { model.actions.selectMeeting(info.id) }
                }
                .padding(24)
                Spacer()
            } else if model.data.detailLoading.contains(info.id), detail.info.notesMD == nil, detail.info.transcriptMD == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L10nKey.meetingsLoading.text).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .notes: NotesTab(model: model, detail: detail, openSpeakers: { tab = .speakers })
                case .transcript: TranscriptTab(model: model, detail: detail)
                case .speakers: SpeakersTab(model: model, detail: detail)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let playback = model.data.playback, playback.meetingID == info.id {
                MiniPlayer(model: model, values: playback)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A click on a hit in the list while this meeting is open moves it to the hit's tab.
        .onChange(of: model.focus) { focus in
            if let focus, focus.meetingID == info.id { tab = MeetingTab(focus.destination) }
        }
        // Leaving the meeting (another one chosen, another section, the meeting deleted) stops the audio.
        .onDisappear {
            model.actions.stopPlayback()
            // The hit was for this visit; coming back to the meeting later opens it the plain way.
            if model.focus?.meetingID == info.id { model.focus = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            HStack(spacing: 6) {
                if let started = info.started {
                    Text(started, format: .dateTime.day().month(.wide).hour().minute())
                }
                if let d = MeetingRowModel.duration(info.durationSeconds) { Text("· \(d)") }
                Text("·")
                StatusLabel(status: MeetingRowModel.status(of: info))
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if let failure = MeetingFailureNotice.of(info), !failure.notes {
                Notice(symbol: "exclamationmark.triangle.fill", text: failure.sentence, tint: .orange)
                if failure.canRetry {
                    Button(L10nKey.commonRetry.text) { model.actions.retryNotes(info.id) }.controlSize(.small)
                }
            }
            if info.audioDeleted { Notice(symbol: "clock.arrow.circlepath", text: L10nKey.meetingAudioDeleted.text) }
            if info.heardNoSystemAudio { Notice(symbol: "exclamationmark.triangle.fill", text: L10nKey.noticeMeetingNoSystemAudio.text, tint: .orange) }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }
}

extension MeetingDetailView {
    /// The title, with Rename beside it; while renaming, a field with Save and Cancel. A recording that is still being
    /// processed cannot be renamed (the daemon refuses), so the button is off then.
    @ViewBuilder var titleRow: some View {
        if renaming {
            HStack(spacing: 8) {
                TextField(L10nKey.meetingsUntitled.text, text: $draftTitle)
                    .textFieldStyle(.roundedBorder).font(.title3)
                    .onSubmit(saveTitle)
                Button(L10nKey.commonSave.text, action: saveTitle)
                    .buttonStyle(.borderedProminent)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10nKey.commonCancel.text) { renaming = false }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MeetingRowModel.displayTitle(of: info)).font(.title2.weight(.semibold)).lineLimit(2)
                Button {
                    // The field starts with the title shown; saving it unchanged sends nothing (see renamedTitle).
                    draftTitle = MeetingRowModel.displayTitle(of: info)
                    renaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(L10nKey.meetingRename.text)
                .accessibilityLabel(L10nKey.meetingRename.text)
                .disabled(info.inProgress())
            }
        }
    }

    private func saveTitle() {
        renaming = false
        guard let title = MeetingRowModel.renamedTitle(draft: draftTitle, shown: MeetingRowModel.displayTitle(of: info)) else { return }
        model.actions.renameMeeting(info.id, title)
    }
}

/// A one-line notice under the title.
private struct Notice: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.callout)
            .padding(.top, 4)
    }
}

// MARK: Notes

private struct NotesTab: View {
    @ObservedObject var model: MainWindowModel
    let detail: MeetingDetail
    let openSpeakers: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                people
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var people: some View {
        let names = PeopleRow.names(detail)
        return Group {
            if !names.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10nKey.meetingPeople.text).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                            HStack(spacing: 6) {
                                SpeakerAvatar(name: n.name, index: i, size: 24)
                                Text(n.name)
                            }
                            .opacity(n.named ? 1 : 0.65)
                        }
                        Button(L10nKey.meetingNameThem.text, action: openSpeakers).buttonStyle(.link)
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let info = detail.info
        if let md = info.notesMD {
            let doc = NotesDocument.parse(md)
            ForEach(Array(doc.sections.enumerated()), id: \.offset) { _, section in
                NotesSection(section: section)
            }
        } else if info.transcriptMD != nil, info.notesPending == "model_missing" || info.status == .transcribed {
            let failure = MeetingFailureNotice.of(info).flatMap { $0.notes ? $0 : nil }
            Callout(symbol: "arrow.down.circle", text: failure?.sentence ?? L10nKey.meetingNotesNeedModel.text) {
                if failure != nil {
                    Button(L10nKey.meetingNotesRetry.text) { model.actions.retryNotes(info.id) }
                } else {
                    Button(L10nKey.meetingNotesGoSettings.text) { model.section = .settings }
                }
            }
        } else if MeetingRowModel.status(of: info).isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(MeetingRowModel.status(of: info).titleKey.text).foregroundStyle(.secondary)
            }
        } else {
            Text(L10nKey.meetingNotesNone.text).foregroundStyle(.secondary)
        }
    }
}

/// The people strip's names: you, then the far side's voices; `named` is false for "Speaker 3".
enum PeopleRow {
    struct Person { var name: String; var named: Bool }

    static func names(_ d: MeetingDetail) -> [Person] {
        guard let s = d.speakers else { return [] }
        var out = [Person(name: L10nKey.meetingSpeakerYou.text, named: true)]
        let live = s.liveVoices
        if live.isEmpty {
            if let one = s.speakers.first(where: { !$0.isVoice }) { out.append(Person(name: one.label, named: !one.name.isEmpty)) }
        } else {
            out += live.map { Person(name: $0.label, named: !$0.name.isEmpty) }
        }
        return out
    }
}

private struct NotesSection: View {
    let section: NotesDocument.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty { Text(section.title).font(.headline) }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .paragraph(let t):
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                case .action(let who, let what, let when):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle").foregroundStyle(.secondary).imageScale(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(inline(what)).fixedSize(horizontal: false, vertical: true)
                            let meta = [who, when].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        InlineMarkdown.attributed(s)
    }
}

private struct Callout<Actions: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Speakers

struct SpeakersTab: View {
    @ObservedObject var model: MainWindowModel
    let detail: MeetingDetail
    /// What the panel edits before it sends anything: the same draft the menu's Speakers panel uses.
    @State private var draft: SpeakerDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let problem = detail.info.diarProblem {
                    Label(problem.shownKey(daemonSaysRetryable: detail.info.voicesRetryable, audioDeleted: detail.info.audioDeleted).text, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    if detail.info.offersVoicesRetry {
                        Button(L10nKey.meetingVoicesRetry.text) { model.actions.retryVoices(detail.info.id) }
                    }
                } else if let error = detail.speakersError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.secondary)
                    Button(L10nKey.commonRetry.text) { model.actions.selectMeeting(detail.info.id) }
                } else {
                    Text(L10nKey.speakersHint.text).foregroundStyle(.secondary)
                }
                if let s = detail.speakers, draft != nil {
                    if s.offersSplit { splitOffer }
                    VStack(spacing: 0) {
                        row(avatar: SpeakerAvatar(name: L10nKey.meetingSpeakerYou.text, index: 0), speaker: nil, state: s)
                        ForEach(Array(shown(s).enumerated()), id: \.element.id) { i, sp in
                            Divider().padding(.leading, 54)
                            row(avatar: SpeakerAvatar(name: sp.label, index: i + 1), speaker: sp, state: s)
                        }
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    let refusal = draft?.refusal(against: s)
                    HStack {
                        Text(draft?.refusalLine(against: s) ?? (refusal ?? .meetingSpeakersFootnote).text).font(.caption)
                            .foregroundStyle(refusal == nil ? Color.secondary : Color.red)
                        Spacer()
                        Button(L10nKey.speakersSave.text) {
                            if let d = draft { model.actions.saveSpeakers(detail.info.id, d.edits(against: s)) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.map { $0.refusal(against: s) != nil || $0.edits(against: s).isEmpty } ?? true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The speakers may arrive after the tab does (or again after a save): the draft follows them.
        .onAppear { resetDraft() }
        .onChange(of: detail.speakers) { _ in resetDraft() }
    }

    private func resetDraft() {
        draft = detail.speakers.map { SpeakerDraft(from: $0) }
    }

    /// The voices, or the single far-side label when the transcript has no voices.
    private func shown(_ s: SpeakersState) -> [SpeakerInfo] {
        let voices = s.liveVoices
        return voices.isEmpty ? s.speakers.filter { !$0.isVoice } : voices
    }

    private var splitOffer: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10nKey.speakersSplit.text).fontWeight(.medium)
                Text(L10nKey.speakersSplitHint.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { draft?.split ?? false }, set: { draft?.split = $0 })).labelsHidden()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func row(avatar: SpeakerAvatar, speaker: SpeakerInfo?, state: SpeakersState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            avatar
            if let sp = speaker {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(sp.label, text: nameBinding(sp))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    if !sp.sample.isEmpty {
                        Text(verbatim: "“\(sp.sample)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if sp.speechSeconds > 0 {
                        Text(L10nKey.meetingSpeakerTime.text(MeetingRowModel.duration(sp.speechSeconds) ?? ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if sp.isVoice, let d = draft {
                    let targets = d.mergeTargets(for: sp.id, in: state)
                    if !targets.isEmpty || d.mergeInto[sp.id] != nil {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(L10nKey.speakersSameAs.text).font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: mergeBinding(sp)) {
                                Text(L10nKey.speakersNotMerged.text).tag("")
                                ForEach(targets, id: \.id) { Text($0.label).tag($0.id) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10nKey.meetingSpeakerYou.text).fontWeight(.medium)
                    let me = model.data.meetingSettings
                    Text(me.yourName.isEmpty ? me.yourNameFallback : me.yourName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func nameBinding(_ sp: SpeakerInfo) -> Binding<String> {
        Binding(get: { draft?.names[sp.id] ?? sp.name }, set: { new in
            draft?.names[sp.id] = MeetingLimits.cap(new, to: MeetingLimits.nameMax, keeping: draft?.names[sp.id] ?? sp.name)
        })
    }

    private func mergeBinding(_ sp: SpeakerInfo) -> Binding<String> {
        Binding(get: { draft?.mergeInto[sp.id] ?? "" },
                set: { draft?.mergeInto[sp.id] = $0.isEmpty ? nil : $0 })
    }
}
