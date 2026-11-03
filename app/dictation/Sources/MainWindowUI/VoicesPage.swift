import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// Voices: the voices that exist (play a sample, rename, delete) and, below, reading selected text aloud (a voice per
/// language). The read-aloud key is set in the menu bar until Task 23 moves it here. «Описать словами» opens a sheet
/// (VoiceDesignSheet); «Взять из файла…» opens the file picker and then its own sheet (VoiceFileSheet).
struct VoicesPage: View {
    @ObservedObject var model: MainWindowModel
    @State private var renaming: VoiceEntry?
    @State private var draft = ""
    @State private var deleting: VoiceEntry?
    @State private var pickingFile = false

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.data.notice { NoticeBar(text: notice) { model.actions.dismissNotice() } }
            }
            .sheet(isPresented: Binding(get: { model.data.voices.designOpen },
                                        set: { if !$0 { model.actions.voiceDesign(.escape) } })) {
                VoiceDesignSheet(flow: model.data.voices.design) { model.actions.voiceDesign($0) }
            }
            .sheet(item: $renaming) { entry in
                RenameVoiceSheet(draft: $draft) {
                    model.actions.renameVoice(entry.id, draft)
                    renaming = nil
                } cancel: {
                    renaming = nil
                }
            }
            .confirmationDialog(deleting.map { L10nKey.voicesDeleteTitle.text($0.label) } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { entry in
                Button(L10nKey.voicesDeleteConfirm.text, role: .destructive) { model.actions.deleteVoice(entry.id) }
                Button(L10nKey.commonCancel.text, role: .cancel) {}
            } message: { _ in
                Text(L10nKey.voicesDeleteBody.text)
            }
    }

    @ViewBuilder private var content: some View {
        switch model.voicesState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10nKey.voicesLoading.text).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreachable(let sentence):
            EmptyState(symbol: "bolt.horizontal.circle", title: L10nKey.meetingsDownTitle.text, message: sentence) {
                Button(L10nKey.commonRetry.text) { model.actions.reloadVoices() }.controlSize(.large)
            }
        case .empty:
            list(stale: nil)
        case .list(let stale):
            list(stale: stale)
        }
    }

    private func list(stale: String?) -> some View {
        VStack(spacing: 0) {
            if let stale {
                NoticeBar(text: stale, symbol: "exclamationmark.triangle.fill", tint: .orange,
                          actionTitle: L10nKey.commonRetry.text) { model.actions.reloadVoices() }
            }
            Form {
                Section {
                    describeRow
                    fileRow
                    if model.data.voices.entries.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "person.wave.2").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                            Text(L10nKey.voicesEmptyTitle.text).font(.headline)
                            Text(L10nKey.voicesEmptyMessage.text).font(.callout).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                    } else {
                        ForEach(model.data.voices.entries) { row($0) }
                    }
                } header: {
                    Text(L10nKey.voicesMine.text)
                }
                Section {
                    HintedRow(title: L10nKey.voicesStandard.text, hint: L10nKey.voicesStandardSubtitle.text) { EmptyView() }
                        .accessibilityElement(children: .combine)
                } header: {
                    Text(L10nKey.voicesBuiltin.text)
                }
                Section {
                    voicePicker(L10nKey.voicesRussian.text, slot: .russian)
                    voicePicker(L10nKey.voicesEnglish.text, slot: .english)
                } header: {
                    Text(L10nKey.voicesReadAloud.text)
                } footer: {
                    Text(L10nKey.voicesReadAloudFooter.text)
                }
            }
            .formStyle(.grouped)
        }
        // A picked file is handed to the app, which measures it and opens the sheet; the sheet is window-modal
        // (`.sheet`), never a modal run loop. Both sit on the list, not on `content` — a second `.sheet` on the
        // view that already carries the design sheet is not supported.
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { model.actions.voiceFile(.picked(url)) }
        }
        .sheet(isPresented: Binding(get: { model.data.voices.file != nil },
                                    set: { if !$0 { model.actions.voiceFile(.escape) } })) {
            if let add = model.data.voices.file {
                VoiceFileSheet(add: add) { model.actions.voiceFile($0) }
            }
        }
    }

    /// «Взять из файла…»: opens the file picker. A clip that is not one the daemon reads is refused in the sheet.
    private var fileRow: some View {
        HStack {
            Button(L10nKey.fileOpen.text) { pickingFile = true }
            Spacer()
        }
    }

    /// «Описать словами…», or why it cannot be used: the studio voice is not installed (Settings has it) or this Mac
    /// cannot run it.
    private var describeRow: some View {
        let availability = model.data.voices.designAvailability
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(L10nKey.voicesDescribe.text) { model.actions.voiceDesign(.open) }
                    .disabled(availability != .available)
                Spacer()
            }
            switch availability {
            case .available:
                EmptyView()
            case .installable:
                HStack(spacing: 6) {
                    Text(L10nKey.voicesDescribeInstallable.text).font(.caption).foregroundStyle(.secondary)
                    Button(L10nKey.voicesDescribeInstall.text) { model.actions.installStudioVoice() }
                        .buttonStyle(.link).font(.caption)
                }
            case .unavailable(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: VoiceEntry) -> some View {
        let playing = model.data.voices.playingID == entry.id
        let subtitle = entry.subtitle(locale: L10nBundle.locale, calendar: .current)
        return HStack(spacing: 10) {
            IconButton(symbol: playing ? "stop.fill" : "play.fill", labelKey: playing ? .a11yPlayStop : .voicesPlay) {
                if playing { model.actions.stopPreview() } else { model.actions.previewVoice(entry.id) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.label), \(subtitle)")
            Spacer(minLength: 12)
            Menu(L10nKey.voicesEdit.text) {
                Button(L10nKey.voicesRename.text) { draft = entry.label; renaming = entry }
                Button(L10nKey.voicesDelete.text, role: .destructive) { deleting = entry }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    /// "Default voice", "Random each time", then the daemon's voices.
    private func voicePicker(_ title: String, slot: VoiceSlot) -> some View {
        Picker(title, selection: model.voice(slot)) {
            Text(L10nKey.voicesDefault.text).tag(String?.none)
            Text(L10nKey.voicesRandom.text).tag(String?.some(MenuSections.randomVoice))
            Divider()
            ForEach(model.data.voices.voices, id: \.self) { id in
                Text(model.data.voices.title(for: id)).tag(String?.some(id))
            }
        }
    }
}

/// The rename field: Return saves, Esc cancels. Save is off while the name would be refused (empty, too long).
private struct RenameVoiceSheet: View {
    @Binding var draft: String
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10nKey.voicesRenameTitle.text).font(.headline)
            TextField(L10nKey.voicesRenameField.text, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if VoiceLabel.clean(draft) != nil { save() } }
            HStack {
                Spacer()
                Button(L10nKey.commonCancel.text, action: cancel).keyboardShortcut(.cancelAction)
                Button(L10nKey.commonSave.text, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(VoiceLabel.clean(draft) == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
