import DictationCore
import SwiftUI

/// «Взять из файла»: the clip that was picked, the name and transcript to send, «Добавить». A window-modal sheet on
/// the Voices page. It holds the text being typed and nothing else: what may be sent, what a taken name means and
/// what the daemon answered is the model's (VoiceFileAdd), and every button is one `VoiceFileAction`. Esc cancels,
/// Return adds.
public struct VoiceFileSheet: View {
    let add: VoiceFileAdd
    let send: (VoiceFileAction) -> Void
    @State private var label: String
    @State private var refText: String

    public init(add: VoiceFileAdd, send: @escaping (VoiceFileAction) -> Void) {
        self.add = add
        self.send = send
        _label = State(initialValue: add.label)
        _refText = State(initialValue: add.refText)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10nKey.fileSheetTitle.text).font(.headline)
            field(L10nKey.fileSheetFile.text) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text(add.fileName).lineLimit(1).truncationMode(.middle)
                    if let length = PhraseScript.durationText(add.seconds) {
                        Spacer(minLength: 4)
                        Text(length).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            field(L10nKey.voicesRenameField.text) {
                TextField("", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10nKey.voicesRenameField.text)
            }
            field(L10nKey.fileSheetRefLabel.text) {
                TextField(L10nKey.fileSheetRefPlaceholder.text, text: $refText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .accessibilityLabel(L10nKey.fileSheetRefLabel.text)
            }
            if let sentence = add.fileProblem ?? add.problem {
                Label(sentence, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = add.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if add.sending {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10nKey.fileAdding.text).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Spacer()
                    Button(L10nKey.commonCancel.text) { send(.escape) }
                    Button(L10nKey.fileSheetAdd.text) { send(.add) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(add.fileProblem != nil || VoiceLabel.clean(label) == nil)
                }
            }
        }
        .onChange(of: label) { _ in pushText() }
        .onChange(of: refText) { _ in pushText() }
        .padding(20)
        .frame(width: 440)
        // Esc is the cancel button's shortcut; while the add is in flight the model keeps the sheet up (mayClose).
        .background(Button("") { send(.escape) }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
    }

    /// The typed text reaches the model as it changes, so Cancel (or Esc) keeps it.
    private func pushText() {
        send(.edit(label: label, refText: refText))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
