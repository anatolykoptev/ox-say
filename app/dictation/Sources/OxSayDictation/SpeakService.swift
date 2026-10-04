import AppKit
import DictationCore

/// The macOS Services entry point for "speak the selected text". The app
/// declares the service in Info.plist (NSServices); when the user picks the
/// item — in a right-click menu or the app's Services menu — macOS starts the
/// app if needed and calls `speakSelection` with the selection on a pasteboard.
///
/// The method only validates and hands the text over: synthesis is async, so
/// errors past this point are reported through the app's own notice (the pill
/// and the menu-bar status line), not the service's error return.
final class SpeakServiceProvider: NSObject {
    /// Called on the main actor with the text to synthesize.
    var onSpeak: ((String) -> Void)?

    @objc(speakSelection:userData:error:)
    func speakSelection(_ pboard: NSPasteboard, userData _: String, error: NSErrorPointer) {
        let raw = pboard.string(forType: .string) ?? ""
        guard let text = SpeechClient.input(raw) else {
            error?.pointee = NSError(
                domain: "OxSayDictation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nothing to speak: the selection is empty."])
            return
        }
        onSpeak?(text)
    }
}
