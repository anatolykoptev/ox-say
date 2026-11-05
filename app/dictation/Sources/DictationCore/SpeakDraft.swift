import Foundation

public enum SpeakDraft {
    /// The editor's text when the page opens: the person's own text when there is one, the
    /// language's sample on the very first run, otherwise empty. `language` is a language code
    /// ("ru", "ru-RU", "en"); anything that is not Russian gets the English sample.
    public static func initial(stored: String?, firstRun: Bool, language: String,
                               text: (L10nKey) -> String = { $0.text }) -> String {
        if let stored { return stored }
        guard firstRun else { return "" }
        return text(language.lowercased().hasPrefix("ru") ? .speakSampleRu : .speakSampleEn)
    }
}
