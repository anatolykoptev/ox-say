import Foundation

/// Where `L10nKey.text` looks its words up. The app reads its own bundle, whose
/// .lproj closest to the user's preferred languages wins; the screenshot harness
/// points `bundle` at one language's .lproj folder to render both in one process.
public enum L10nBundle {
    public static var bundle: Bundle = .main

    /// The locale dates, numbers and durations are written in: the language the
    /// bundle resolved to, not the system region (a Russian window on an English Mac
    /// must not print English month names).
    public static var locale: Locale = {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }()
}

/// Resolves an L10nKey through the bundle's Localizable.strings. The language
/// is picked the way the system does: the .lproj closest to the user's
/// preferred languages, en when neither matches.
extension L10nKey {
    public var text: String {
        NSLocalizedString(rawValue, bundle: L10nBundle.bundle, comment: "")
    }

    /// The text with its `%@` filled in.
    public func text(_ argument: String) -> String {
        String(format: text, argument)
    }
}
