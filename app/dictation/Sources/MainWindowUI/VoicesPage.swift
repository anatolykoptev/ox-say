import DictationCore
import SwiftUI

/// Voices: reading selected text aloud (a voice per language) and the voices that exist. The read-aloud key and the
/// Studio features are set in the menu bar; nothing here is shown that the window cannot change or read for real.
struct VoicesPage: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        Form {
            Section {
                voicePicker(L10nKey.voicesRussian.text, slot: .russian)
                voicePicker(L10nKey.voicesEnglish.text, slot: .english)
            } header: {
                Text(L10nKey.voicesReadAloud.text)
            } footer: {
                Text(L10nKey.voicesReadAloudFooter.text)
            }
            Section {
                if model.data.voices.voices.isEmpty {
                    Text(L10nKey.voicesMineEmpty.text).foregroundStyle(.secondary)
                } else {
                    ForEach(model.data.voices.voices, id: \.self) { name in
                        Label(name, systemImage: "waveform.circle").labelStyle(.titleAndIcon)
                    }
                }
            } header: {
                Text(L10nKey.voicesMine.text)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10nKey.sectionVoices.text)
    }

    /// "Default voice", "Random each time", then the daemon's voices.
    private func voicePicker(_ title: String, slot: VoiceSlot) -> some View {
        Picker(title, selection: model.voice(slot)) {
            Text(L10nKey.voicesDefault.text).tag(String?.none)
            Text(L10nKey.voicesRandom.text).tag(String?.some(MenuSections.randomVoice))
            Divider()
            ForEach(model.data.voices.voices, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }
}
