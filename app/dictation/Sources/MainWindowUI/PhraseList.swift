import DictationCore
import SwiftUI

/// The phrases of a finished studio project: what each says, how it sounds (mood, variant) and what can be done to it.
/// Every row acts on its own phrase only; while the daemon works on one the project is busy and the row says what is
/// being done. The values are `PhraseEditing.rows`'s.
struct PhraseList: View {
    @ObservedObject var model: MainWindowModel
    let job: ProduceJob
    @State private var editing: PhraseRowValue?

    var body: some View {
        let values = model.data.speak
        let rows = values.phrases
        let busy = PhraseEditing.isBusy(values.phraseWork, project: job.id) || !PhraseEditing.canEditText(status: job.status)
        let showsMood = values.showsMood(voices: model.data.voices.entries)
        if !rows.isEmpty {
            Form {
                Section(L10nKey.speakPhrasesTitle.text) {
                    ForEach(rows) { row in
                        PhraseRow(row: row, work: PhraseEditing.shownWork(values.phraseWork, project: job.id, chunk: row.index),
                                  busy: busy, playing: values.playingPhrase == row.index && values.playback == .playing,
                                  showsMood: showsMood, actions: model.actions,
                                  selected: model.advanced && values.panelPhrase == row.index,
                                  // With Advanced on a click chooses the phrase the voice panel's pace and pause go to.
                                  select: model.advanced ? { model.data.speak.panelPhrase = row.index } : nil) { editing = row }
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(item: $editing) { row in
                PhraseTextSheet(text: values.phraseChunks.first { $0.index == row.index }?.text ?? row.preview) { words in
                    model.actions.phraseEditText(row.index, words)
                }
            }
        }
    }
}

private struct PhraseRow: View {
    let row: PhraseRowValue
    let work: PhraseWork?
    let busy: Bool
    let playing: Bool
    let showsMood: Bool
    let actions: MainWindowActions
    let selected: Bool
    let select: (() -> Void)?
    let edit: () -> Void

    var body: some View {
        let variant = PhraseEditing.variantLabel(index: row.variant, of: row.variants) { $0.text }
        HStack(alignment: .top, spacing: 10) {
            IconButton(symbol: playing ? "stop.fill" : "play.fill", labelKey: playing ? .speakStop : .speakPlay) {
                actions.phrasePlay(row.index)
            }
            .disabled(!row.playable || busy)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.preview).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let work {
                        ProgressView().controlSize(.mini)
                        Text(Self.workText(work.kind))
                    } else if row.state == .rendering {
                        ProgressView().controlSize(.mini)
                        Text(variant)
                    } else {
                        Text(variant)
                        if row.state == .needsListen {
                            Text("·")
                            Text(L10nKey.speakPhraseListen.text).foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsMood {
                MoodChips(selected: row.mood, custom: row.customStyle) { actions.phraseMood(row.index, $0) }.disabled(busy)
            }
            Menu {
                Button(L10nKey.speakVariant.text) { actions.phraseVariant(row.index) }
                Button(L10nKey.speakPhrasePickOther.text) { actions.phrasePickOther(row.index) }.disabled(row.variants < 2)
                Divider()
                Button(L10nKey.speakPhraseEdit.text, action: edit)
            } label: {
                Label(L10nKey.speakPhraseActions.text, systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10nKey.speakPhraseActions.text)
            .disabled(busy)
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { select?() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func workText(_ kind: PhraseWork.Kind) -> String {
        switch kind {
        case .variant: return L10nKey.speakPhraseWorkVariant.text
        case .pick: return L10nKey.speakPhraseWorkPick.text
        case .mood: return L10nKey.speakPhraseWorkMood.text
        case .text: return L10nKey.speakPhraseWorkText.text
        case .pace, .pause, .loudness: return L10nKey.speakPanelBusy.text
        }
    }
}

/// «Править текст…»: the words of one phrase in a sheet; only that phrase is rendered again.
private struct PhraseTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let save: (String) -> Void

    init(text: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10nKey.speakPhraseEditTitle.text).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 380, minHeight: 120)
                .accessibilityLabel(L10nKey.speakPhraseEditTitle.text)
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10nKey.commonSave.text) {
                    save(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
