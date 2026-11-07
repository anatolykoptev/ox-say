import DictationCore
import SwiftUI

/// The mood of one phrase: «Как обычно» or one of five words. A native pop-up button; choosing a word re-renders that
/// phrase only. Drawn by `PhraseList` only where `PhraseEditing.showsMood` says the voice answers a mood.
struct MoodChips: View {
    let selected: Mood?
    let choose: (Mood?) -> Void

    var body: some View {
        Picker(L10nKey.speakPhraseMood.text, selection: Binding(get: { selected }, set: { choose($0) })) {
            Text(L10nKey.speakPhraseMoodNone.text).tag(Mood?.none)
            Divider()
            ForEach(Mood.allCases, id: \.self) { mood in
                Text(SpeakText.moodName(mood) { $0.text }).tag(Mood?.some(mood))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(L10nKey.speakPhraseMood.text)
    }
}
