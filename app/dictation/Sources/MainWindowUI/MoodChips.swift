import DictationCore
import SwiftUI

/// The mood of one phrase: «Как обычно» or one of five words. A native pop-up button; choosing a word re-renders that
/// phrase only. A style set elsewhere (none of the five) is an entry of its own, so «Как обычно» can clear it. Drawn by
/// `PhraseList` only where `PhraseEditing.showsMood` says the voice answers a mood.
struct MoodChips: View {
    private enum Choice: Hashable {
        case asUsual, custom, mood(Mood)
    }

    let selected: Mood?
    let custom: String?
    let choose: (Mood?) -> Void

    private var current: Choice {
        if let selected { return .mood(selected) }
        return custom == nil ? .asUsual : .custom
    }

    var body: some View {
        Picker(L10nKey.speakPhraseMood.text, selection: Binding(get: { current }, set: { pick($0) })) {
            Text(L10nKey.speakPhraseMoodNone.text).tag(Choice.asUsual)
            if let custom {
                Text(L10nKey.speakMoodCustom.text(custom)).tag(Choice.custom)
            }
            Divider()
            ForEach(Mood.allCases, id: \.self) { mood in
                Text(SpeakText.moodName(mood) { $0.text }).tag(Choice.mood(mood))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(L10nKey.speakPhraseMood.text)
    }

    private func pick(_ choice: Choice) {
        switch choice {
        case .asUsual: choose(nil)
        case .mood(let mood): choose(mood)
        case .custom: break
        }
    }
}
