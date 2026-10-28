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

    /// #337.1: the reason of a lost microphone or system-audio tap is a framework error in English; the notice says the
    /// loss in the user's language and the reason goes to the log.
    /// Mutation: en "notice.meeting.tap_lost" gets ": %@" back -> RED.
    func testTheLostSourceNoticesCarryNoRawReason() {
        for locale in ["en", "ru"] {
            let table = ShippedStrings.table(locale)
            for key in ["notice.meeting.mic_lost", "notice.meeting.tap_lost"] {
                XCTAssertFalse((table[key] ?? "%").contains("%"), "\(locale) \(key) takes a reason: \(table[key] ?? "")")
            }
        }
    }

    /// #337.3: the progress row continues a dash, so its Russian form is lower case; the sentence form that follows
    /// "Сохранено как X." starts with a capital.
    /// Mutation: ru "studio.progress.listen_one" back to "Нужно прослушать частей: 1" -> RED.
    func testTheRussianListenRowContinuesTheLineAndTheSentenceStartsOne() {
        let ru = ShippedStrings.table("ru")
        for key in ["studio.progress.listen_one", "studio.progress.listen_many"] {
            XCTAssertTrue(ru[key]?.first?.isLowercase == true, "\(key) is a row form: \(ru[key] ?? "")")
        }
        for key in ["studio.finish.listen_one", "studio.finish.listen_many"] {
            XCTAssertTrue(ru[key]?.first?.isUppercase == true, "\(key) is a sentence form: \(ru[key] ?? "")")
        }
        for key in ["studio.progress.listen_many", "studio.finish.listen_many"] {
            XCTAssertFalse(ru[key]?.contains("частей: ") ?? true, "no \"частей: N\" calque: \(ru[key] ?? "")")
        }
    }

    /// #342.3: the per-app pick says what the badge says ("Don't ask for X"), not "Don't record".
    /// Mutation: en "settings.apps.never" back to "Don't record" -> RED.
    func testThePerAppNeverPickReadsLikeTheBadge() {
        XCTAssertEqual(ShippedStrings.table("en")["settings.apps.never"], "Never ask")
        XCTAssertEqual(ShippedStrings.table("ru")["settings.apps.never"], "Не спрашивать")
    }

    /// #340.3: a row that now offers Try Again must not keep the old reason.
    /// Mutation: ru "meeting.diar.unavailable.retry_now" loses «можно найти» -> RED.
    func testTheRetryableRowSaysTheVoicesCanBeFoundNow() {
        XCTAssertTrue(ShippedStrings.table("en")["meeting.diar.unavailable.retry_now"]?.contains("can be found now") == true)
        XCTAssertTrue(ShippedStrings.table("ru")["meeting.diar.unavailable.retry_now"]?.contains("можно найти") == true)
    }
}
