import DictationCore
import SwiftUI

/// Voices: reading selected text aloud (key and a voice per language), the voices that exist, and the studio.
struct VoicesPage: View {
    @ObservedObject var model: MainWindowModel

    private var v: Binding<VoicesValues> { $model.data.voices }

    var body: some View {
        Form {
            Section {
                Picker(L10nKey.voicesKey.text, selection: v.speakKeyID) {
                    ForEach(model.data.voices.speakKeys) { k in
                        Text(k.takenByMac ? "\(k.title) (\(L10nKey.dictationKeyTaken.text))" : k.title)
                            .tag(k.id).disabled(k.takenByMac)
                    }
                }
                voicePicker(L10nKey.voicesRussian.text, selection: v.russianVoice)
                voicePicker(L10nKey.voicesEnglish.text, selection: v.englishVoice)
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
                if case .installed = model.data.voices.studio {
                    Button(L10nKey.voicesCreate.text) { model.actions.createVoice() }
                }
            } header: {
                Text(L10nKey.voicesMine.text)
            } footer: {
                if case .installed = model.data.voices.studio { Text(L10nKey.voicesCreateFooter.text) }
            }
            Section {
                HintedRow(title: L10nKey.voicesStudio.text, hint: L10nKey.voicesStudioFooter.text) {
                    switch model.data.voices.studio {
                    case .installed:
                        Label(L10nKey.voicesStudioInstalled.text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .missing:
                        Button(L10nKey.voicesStudioInstall.text) { model.actions.installStudioVoice() }
                    case .unavailable(let why):
                        Text(why).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing)
                    }
                }
                if case .installed = model.data.voices.studio {
                    Button(L10nKey.voicesNewVoiceover.text) { model.actions.newVoiceover() }
                    Button(L10nKey.voicesOpenFolder.text) { model.actions.openVoiceoversFolder() }
                        .disabled(!model.data.voices.hasVoiceoversFolder)
                }
            } header: {
                Text(L10nKey.voicesVoiceovers.text)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10nKey.sectionVoices.text)
    }

    /// "Default voice", "Random each time", then the daemon's voices.
    private func voicePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text(L10nKey.voicesDefault.text).tag(String?.none)
            Text(L10nKey.voicesRandom.text).tag(String?.some(MenuSections.randomVoice))
            Divider()
            ForEach(model.data.voices.voices, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }
}
