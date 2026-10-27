import DictationCore
import SwiftUI

/// Dictation: the key and how it works, what happens to sound, and the last dictations.
struct DictationPage: View {
    @ObservedObject var model: MainWindowModel

    private var d: Binding<DictationValues> { $model.data.dictation }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    KeyCap(title: model.data.dictation.keys.first { $0.id == model.data.dictation.keyID }?.title ?? "")
                    Text(L10nKey.dictationIntro.text)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                Picker(L10nKey.dictationKey.text, selection: d.keyID) {
                    ForEach(model.data.dictation.keys) { k in
                        Text(k.takenByMac ? "\(k.title) (\(L10nKey.dictationKeyTaken.text))" : k.title)
                            .tag(k.id).disabled(k.takenByMac)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10nKey.dictationMode.text)
                    radio(L10nKey.dictationModeHold.text, .hold)
                    radio(L10nKey.dictationModeToggle.text, .toggle)
                }
                Picker(L10nKey.menuSoundWhileDictating.text, selection: d.sound) {
                    ForEach(SoundWhileDictating.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                }
            }
            Section {
                if model.data.dictation.recent.isEmpty {
                    Text(L10nKey.dictationRecentEmpty.text).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.data.dictation.recent.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L10nKey.commonCopy.text) { model.actions.copyDictation(text) }
                        }
                    }
                    Button(L10nKey.menuPasteLastDictation.text) { model.actions.pasteLastDictation() }
                }
            } header: {
                Text(L10nKey.menuRecentDictations.text)
            } footer: {
                Text(L10nKey.dictationRecentFooter.text)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10nKey.sectionDictation.text)
    }

    private func radio(_ title: String, _ choice: DictationModeChoice) -> some View {
        Button { model.data.dictation.mode = choice } label: {
            HStack(spacing: 8) {
                Image(systemName: model.data.dictation.mode == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.data.dictation.mode == choice ? Color.accentColor : .secondary)
                Text(title).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}
