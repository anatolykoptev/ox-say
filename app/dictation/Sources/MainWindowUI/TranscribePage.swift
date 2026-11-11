import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// Расшифровка: drop a recording (or pick one), get the text and the subtitles. The list under the drop area is what the
/// daemon keeps. Every decision is `TranscribeSession`'s; this page draws `TranscribePageState` and calls closures.
struct TranscribePage: View {
    @ObservedObject var model: MainWindowModel
    @State private var pickingFile = false
    @State private var targeted = false
    @State private var deleting: TranscriptEntry?

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.data.notice { NoticeBar(text: notice) { model.actions.dismissNotice() } }
            }
            .toolbar {
                ToolbarItem {
                    Button(L10nKey.transcribePick.text) { pickingFile = true }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result { model.actions.transcribePick(url) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.actions.transcribePick(url)
                return true
            } isTargeted: { targeted = $0 }
            .confirmationDialog(deleting.map { L10nKey.transcribeDeleteTitle.text($0.title) } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { entry in
                Button(L10nKey.transcribeDeleteConfirm.text, role: .destructive) { model.actions.transcribeDelete(entry.id) }
                Button(L10nKey.commonCancel.text, role: .cancel) {}
            } message: { _ in
                Text(L10nKey.transcribeDeleteBody.text)
            }
    }

    @ViewBuilder private var content: some View {
        switch model.transcribeState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10nKey.transcribeLoading.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .offline(let sentence):
            ContentUnavailableView {
                Label(L10nKey.meetingsDownTitle.text, systemImage: "bolt.horizontal.circle")
            } description: {
                Text(sentence)
            } actions: {
                Button(L10nKey.commonRetry.text) { model.actions.transcribeReload() }.controlSize(.large)
            }
        case .empty:
            DropArea(targeted: targeted, large: true) { pickingFile = true }
                .padding(24)
        case .list(let stale):
            list(stale: stale, working: nil)
        case .working(let name):
            list(stale: nil, working: name)
        }
    }

    private func list(stale: String?, working: String?) -> some View {
        VStack(spacing: 0) {
            if let stale {
                NoticeBar(text: stale, symbol: "exclamationmark.triangle.fill", tint: .orange,
                          actionTitle: L10nKey.commonRetry.text) { model.actions.transcribeReload() }
            }
            Form {
                Section {
                    DropArea(targeted: targeted, large: false) { pickingFile = true }
                    if let working { workingRow(working) }
                }
                if !model.data.transcribe.entries.isEmpty {
                    Section {
                        ForEach(model.data.transcribe.entries) { row($0) }
                    } header: {
                        Text(L10nKey.transcribeDone.text)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The file that is being transcribed: its name and a spinner that never claims a percentage.
    private func workingRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(L10nKey.transcribeWorking.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(L10nKey.transcribeWorking.text)")
    }

    private func row(_ entry: TranscriptEntry) -> some View {
        let selected = entry.id == model.data.transcribe.selectedID
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? L10nKey.transcribeDefaultName.text : entry.title).lineLimit(1).truncationMode(.middle)
                Text(entry.subtitle(locale: L10nBundle.locale, calendar: .current)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu(L10nKey.transcribeText.text) {
                Button(L10nKey.transcribeCopy.text) { model.actions.transcribeCopy(entry.id) }
                Button(L10nKey.transcribeSave.text) { model.actions.transcribeSave(entry.id, .text) }
            }
            .fixedSize()
            .accessibilityLabel("\(entry.title), \(L10nKey.transcribeText.text)")
            Button(L10nKey.transcribeSubtitles.text) { model.actions.transcribeSave(entry.id, .srt) }
                .accessibilityLabel("\(entry.title), \(L10nKey.transcribeSubtitles.text)")
            Menu(L10nKey.transcribeMore.text) {
                Button(L10nKey.transcribeSaveVTT.text) { model.actions.transcribeSave(entry.id, .vtt) }
                Button(L10nKey.transcribeSaveJSON.text) { model.actions.transcribeSave(entry.id, .json) }
                Divider()
                Button(L10nKey.transcribeDelete.text, role: .destructive) { deleting = entry }
            }
            .fixedSize()
            .accessibilityLabel("\(entry.title), \(L10nKey.transcribeMore.text)")
        }
        .padding(.vertical, 2)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.actions.transcribeSelect(entry.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The place to drop a recording. The button is the keyboard path to the same file picker.
private struct DropArea: View {
    let targeted: Bool
    let large: Bool
    let pick: () -> Void

    var body: some View {
        VStack(spacing: large ? 10 : 6) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: large ? 34 : 22, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            Text(targeted ? L10nKey.transcribeDropTargeted.text : L10nKey.transcribeDropTitle.text).font(large ? .title3 : .headline)
            if large {
                Text(L10nKey.transcribeDropMessage.text).font(.callout).foregroundStyle(.secondary)
            }
            Button(L10nKey.transcribePick.text, action: pick).controlSize(large ? .large : .regular)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: large ? 220 : 96, maxHeight: large ? .infinity : nil)
        .padding(.vertical, large ? 20 : 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.10) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}
