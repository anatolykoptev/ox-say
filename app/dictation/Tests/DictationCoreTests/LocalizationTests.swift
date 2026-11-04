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
        XCTAssertTrue(text.contains("Озвучка"), "ru.lproj must translate the sidebar")
    }

    /// The recording cap sentence names the cap the app really has (6 h, `MeetingLimits.maxRecordingSeconds`), and the
    /// `too_long` sentence names no number at all: the daemon says `too_long` above 6 h on the default engine but
    /// above 2 h on a Mac that chose pyannote, and the app cannot tell which engine said it.
    /// Mutations: en "notice.meeting.cap_reached" back to "2 hours" -> RED; en "meeting.diar.unavailable.too_long" given
    /// a number ("longer than 6 hours") -> RED.
    func testTheCapSentencesNameTheRealCapAndTooLongNamesNone() {
        XCTAssertEqual(MeetingLimits.maxRecordingSeconds, 6 * 3600 - 60)
        let en = ShippedStrings.table("en"), ru = ShippedStrings.table("ru")
        XCTAssertTrue((en["notice.meeting.cap_reached"] ?? "").contains("6 hours"), en["notice.meeting.cap_reached"] ?? "")
        XCTAssertTrue((ru["notice.meeting.cap_reached"] ?? "").contains("6 часов"), ru["notice.meeting.cap_reached"] ?? "")
        for table in [en, ru] {
            let text = table["meeting.diar.unavailable.too_long"] ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "no number in: \(text)")
        }
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

    /// #342.3: the per-app pick stays "Don't record": unambiguous next to "Record automatically" / "Ask me first" (the
    /// badge's "Don't ask for X" is a different sentence about the same pick).
    /// Mutation: en "settings.apps.never" -> "Never ask" -> RED.
    func testThePerAppNeverPickStaysUnambiguous() {
        XCTAssertEqual(ShippedStrings.table("en")["settings.apps.never"], "Don't record")
        XCTAssertEqual(ShippedStrings.table("ru")["settings.apps.never"], "Не записывать")
    }

    /// #340.3: a row that now offers Try Again must not keep the old reason.
    /// Mutation: ru "meeting.diar.unavailable.retry_now" loses «можно найти» -> RED.
    func testTheRetryableRowSaysTheVoicesCanBeFoundNow() {
        XCTAssertTrue(ShippedStrings.table("en")["meeting.diar.unavailable.retry_now"]?.contains("can be found now") == true)
        XCTAssertTrue(ShippedStrings.table("ru")["meeting.diar.unavailable.retry_now"]?.contains("можно найти") == true)
    }

    /// User-facing copy names the app "OxSay" — the lowercase "ox-say" is the binary, the repo and the
    /// daemon, never what a person reads. Keys and code identifiers keep it; no value may. The permission
    /// prompts are user-facing too: both InfoPlist.strings files and the Info.plist heredoc in build.sh.
    /// Mutation: any en/ru value back to "ox-say" -> RED; an InfoPlist value back to "ox-say" -> RED.
    func testNoUserFacingStringSpellsTheAppInLowerCase() {
        for locale in ["en", "ru"] {
            for (key, value) in ShippedStrings.table(locale) where value.contains("ox-say") {
                XCTFail("\(locale).lproj \(key) has a lowercase \"ox-say\": \(value)")
            }
            let plistStrings = packageRoot.appendingPathComponent("Resources/\(locale).lproj/InfoPlist.strings")
            for value in Self.stringsValues(in: plistStrings) where value.contains("ox-say") {
                XCTFail("\(locale).lproj InfoPlist.strings has a lowercase \"ox-say\": \(value)")
            }
        }
        let build = packageRoot.appendingPathComponent("build.sh")
        let script = (try? String(contentsOf: build, encoding: .utf8)) ?? ""
        let plist = script.range(of: "cat > \"$app/Contents/Info.plist\"").map {
            String(script[$0.lowerBound..<(script.range(of: "\nEOF", range: $0.upperBound..<script.endIndex)?.lowerBound ?? script.endIndex)])
        } ?? ""
        XCTAssertFalse(plist.isEmpty, "the Info.plist heredoc in build.sh was not found")
        for value in Self.plistStringValues(in: plist) where value.contains("ox-say") {
            XCTFail("Info.plist in build.sh has a lowercase \"ox-say\": \(value)")
        }
    }

    /// The right-hand values of `"key" = "value";` lines of a .strings file.
    private static func stringsValues(in url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let re = try! NSRegularExpression(pattern: #""[^"\n]+"\s*=\s*"((?:[^"\\\n]|\\.)*)""#)
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The `<string>…</string>` element contents of a plist text.
    private static func plistStringValues(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"<string>([^<]*)</string>"#)
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Every automatic stop says so, neutrally (it can also be a muted listener, not only a hang-up).
    /// Mutation: ru "notice.meeting.call_ended" emptied -> RED.
    func testTheCallEndedNoticeExists() {
        XCTAssertEqual(ShippedStrings.table("en")["notice.meeting.call_ended"], "Recording stopped automatically: nobody on the call has spoken for a while.")
        XCTAssertEqual(ShippedStrings.table("ru")["notice.meeting.call_ended"], "Запись остановлена автоматически: в звонке давно никто не говорит.")
    }
}
