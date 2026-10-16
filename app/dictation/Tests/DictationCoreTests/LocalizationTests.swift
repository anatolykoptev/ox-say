import Foundation
import XCTest
@testable import DictationCore

/// The window's and the new menu items' strings live in Localizable.strings
/// keyed by L10nKey. The enum is the source of truth for which keys exist —
/// the files are checked against it, never against a hand-written list.
final class LocalizationTests: XCTestCase {
    /// …/app/dictation/Tests/DictationCoreTests/<this file> → the package root.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The "key" = "value"; pairs of a Localizable.strings file. Keys are dot
    /// names of ASCII letters and digits; anything else (comments, blanks) is
    /// not a pair.
    private func keys(of locale: String) -> Set<String> {
        let url = packageRoot.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var keys: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            guard let range = line.range(of: #"^"([A-Za-z0-9._]+)"\s*="#, options: .regularExpression) else { continue }
            keys.insert(String(line[range].dropFirst().prefix { $0 != "\"" }))
        }
        return keys
    }

    func testBothLocalesCarryTheSameKeySet() {
        XCTAssertEqual(keys(of: "en"), keys(of: "ru"), "en.lproj and ru.lproj must hold the same keys")
    }

    func testEveryUsedKeyExistsInBothLocales() {
        let used = Set(L10nKey.allCases.map(\.rawValue))
        XCTAssertFalse(used.isEmpty)
        for locale in ["en", "ru"] {
            XCTAssertEqual(used.subtracting(keys(of: locale)), [],
                           "keys missing from \(locale).lproj")
        }
    }

    /// A file of nothing but keys that map to themselves would still pass the
    /// set checks: pin that the values are real text in the right script.
    func testTheRussianFileActuallyHoldsRussian() {
        let url = packageRoot.appendingPathComponent("Resources/ru.lproj/Localizable.strings")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("Ролик"), "ru.lproj must translate the sidebar")
    }
}
