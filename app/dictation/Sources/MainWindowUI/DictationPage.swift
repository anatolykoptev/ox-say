import DictationCore
import SwiftUI

/// Dictation: the key and how it works, what happens to sound, and the last dictations.
struct DictationPage: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    if let key = model.data.dictation.keyTitle { KeyCap(title: key) }
                    Text(L10nKey.dictationIntro.text)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10nKey.dictationMode.text)
                    radio(L10nKey.dictationModeHold.text, .hold)
                    radio(L10nKey.dictationModeToggle.text, .toggle)
                }
                Picker(L10nKey.menuSoundWhileDictating.text, selection: model.sound) {
                    ForEach(SoundWhileDictating.allCases, id: \.self) { Text($0.titleKey.text).tag($0) }
                }
            }
            Section {
                if model.data.dictation.recent.isEmpty {
                    Text(L10nKey.dictationRecentEmpty.text).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.data.dictation.recent.enumerated()), id: \.offset) { _, text in
                        Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
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

    private func radio(_ title: String, _ choice: HotkeyMode) -> some View {
        Button { model.hotkeyMode.wrappedValue = choice } label: {
            HStack(spacing: 8) {
                Image(systemName: model.data.dictation.mode == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.data.dictation.mode == choice ? Color.accentColor : .secondary)
                Text(title).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}
