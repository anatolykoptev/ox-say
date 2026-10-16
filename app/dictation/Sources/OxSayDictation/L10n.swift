import AppKit
import DictationCore

/// Resolves an L10nKey through the bundle's Localizable.strings. The language
/// is picked the way the system does: the .lproj closest to the user's
/// preferred languages, en when neither matches.
extension L10nKey {
    var text: String {
        NSLocalizedString(rawValue, bundle: .main, comment: "")
    }
}
