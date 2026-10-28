import XCTest
@testable import DictationCore

final class MenuSectionsTests: XCTestCase {
    private func titles(_ rows: [MenuRow]) -> [String] {
        rows.map { row in
            switch row {
            case .header(let title): return "# \(title)"
            case .item(let title, _, _, _): return title
            case .separator: return "---"
            }
        }
    }

    func testVoiceMenuHasARussianAndAnEnglishSection() {
        let rows = MenuSections.voiceRows(known: ["ru-anna", "en-sam"], russian: nil, english: nil, text: ShippedStrings.localizer("en"))
        XCTAssertEqual(titles(rows), [
            "# Russian", "Default voice", "Random each time", "ru-anna", "en-sam",
            "---",
            "# English", "Default voice", "Random each time", "ru-anna", "en-sam",
        ])
    }

    func testVoiceMenuMarksEachLanguagesOwnPick() {
        let rows = MenuSections.voiceRows(known: ["ru-anna", "en-sam"], russian: "ru-anna", english: "default", text: ShippedStrings.localizer("en"))
        let russianPick = MenuRow.item(title: "ru-anna", isOn: true, isEnabled: true, action: .pickVoice(.russian, name: "ru-anna"))
        let englishNotPicked = MenuRow.item(title: "ru-anna", isOn: false, isEnabled: true, action: .pickVoice(.english, name: "ru-anna"))
        let englishRandom = MenuRow.item(title: "Random each time", isOn: true, isEnabled: true, action: .pickVoice(.english, name: "default"))
        let russianDefault = MenuRow.item(title: "Default voice", isOn: false, isEnabled: true, action: .pickVoice(.russian, name: nil))
        XCTAssertTrue(rows.contains(russianPick))
        XCTAssertTrue(rows.contains(englishNotPicked))
        XCTAssertTrue(rows.contains(englishRandom))
        XCTAssertTrue(rows.contains(russianDefault))
    }

    func testNoPickChecksDefaultVoiceInBothSections() {
        let rows = MenuSections.voiceRows(known: [], russian: nil, english: nil, text: ShippedStrings.localizer("en"))
        let defaults = rows.filter { $0 == .item(title: "Default voice", isOn: true, isEnabled: true, action: .pickVoice(.russian, name: nil)) ||
            $0 == .item(title: "Default voice", isOn: true, isEnabled: true, action: .pickVoice(.english, name: nil)) }
        XCTAssertEqual(defaults.count, 2)
    }

    func testVoiceMenuShowsLoadingUntilTheDaemonAnswers() {
        let rows = MenuSections.voiceRows(known: nil, russian: nil, english: nil, text: ShippedStrings.localizer("en"))
        let loading = MenuRow.item(title: "Loading…", isOn: false, isEnabled: false, action: nil)
        XCTAssertEqual(rows.filter { $0 == loading }.count, 2)
        XCTAssertFalse(MenuSections.voiceRows(known: [], russian: nil, english: nil, text: ShippedStrings.localizer("en")).contains(loading))
    }

    private func keys(_ names: [String], on: Int, disabled: Set<Int> = []) -> [ShortcutMenu.Item] {
        names.enumerated().map { index, name in
            ShortcutMenu.Item(title: disabled.contains(index) ? "\(name) (a macOS shortcut)" : name,
                              isEnabled: !disabled.contains(index), isOn: index == on)
        }
    }

    func testShortcutsMenuHoldsTheDictationAndTheSpeakKeys() {
        let rows = MenuSections.shortcutRows(dictation: keys(["⌃Space", "⌥Space"], on: 0),
                                             speak: keys(["⌃⌥S", "⌃⌥R"], on: 1), text: ShippedStrings.localizer("en"))
        XCTAssertEqual(titles(rows), [
            "# Dictation", "⌃Space", "⌥Space",
            "---",
            "# Speak Selection", "⌃⌥S", "⌃⌥R",
        ])
    }

    func testShortcutRowsKeepTheirPlanStateAndTheirOwnAction() {
        let rows = MenuSections.shortcutRows(dictation: keys(["⌃Space", "⌥Space"], on: 1, disabled: [0]),
                                             speak: keys(["⌃⌥S", "⌃⌥R"], on: 0))
        XCTAssertTrue(rows.contains(.item(title: "⌃Space (a macOS shortcut)", isOn: false, isEnabled: false, action: .pickDictationKey(0))))
        XCTAssertTrue(rows.contains(.item(title: "⌥Space", isOn: true, isEnabled: true, action: .pickDictationKey(1))))
        XCTAssertTrue(rows.contains(.item(title: "⌃⌥S", isOn: true, isEnabled: true, action: .pickSpeakKey(0))))
        XCTAssertTrue(rows.contains(.item(title: "⌃⌥R", isOn: false, isEnabled: true, action: .pickSpeakKey(1))))
    }

    func testEveryPlanRowReachesTheMergedMenu() {
        let dictation = keys(["a", "b", "c"], on: 2)
        let speak = keys(["x", "y"], on: 0)
        let rows = MenuSections.shortcutRows(dictation: dictation, speak: speak)
        let actions = rows.compactMap { row -> MenuAction? in
            if case .item(_, _, _, let action) = row { return action }
            return nil
        }
        XCTAssertEqual(actions, [.pickDictationKey(0), .pickDictationKey(1), .pickDictationKey(2),
                                 .pickSpeakKey(0), .pickSpeakKey(1)])
    }
}
