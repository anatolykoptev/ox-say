import XCTest
@testable import DictationCore

final class SectionsTests: XCTestCase {
    private let all = Set(MainSection.allCases)

    func testTheSidebarOrderIsTheBindingOrder() {
        XCTAssertEqual(MainWindowSpec.sections(advanced: false, live: all),
                       [.speak, .voices, .dictation, .meetings, .transcribe, .settings])
        XCTAssertEqual(MainWindowSpec.sections(advanced: true, live: all),
                       [.speak, .voices, .dictation, .meetings, .transcribe, .models, .settings])
    }

    func testASectionWithNothingBehindItIsNotListed() {
        XCTAssertEqual(MainWindowSpec.sections(advanced: true, live: [.meetings, .settings]), [.meetings, .settings])
    }

    func testTheSwitchPersists() {
        let d = UserDefaults(suiteName: "SectionsTests.\(UUID())")!
        XCTAssertFalse(AdvancedMode.isOn(d))
        AdvancedMode.set(true, in: d)
        XCTAssertTrue(AdvancedMode.isOn(d))
        AdvancedMode.set(false, in: d)
        XCTAssertFalse(AdvancedMode.isOn(d))
    }

    func testSwitchingOffOnModelsMovesToTheFirstSectionLeft() {
        XCTAssertEqual(AdvancedMode.section(after: false, current: .models), MainWindowSpec.sections(advanced: false).first)
        XCTAssertEqual(AdvancedMode.section(after: false, current: .voices), .voices)
        XCTAssertEqual(AdvancedMode.section(after: true, current: .models), .models)
    }

    /// First run lands on Озвучка once it is live; a stored section always wins; Meetings stays the default until then.
    func testNoStoredSectionLandsOnTheFirstRunSectionAndAStoredOneWins() {
        let d = UserDefaults(suiteName: "SectionsTests.\(UUID())")!
        XCTAssertEqual(WindowRestoration.load(d, advanced: false).section, MainWindowSpec.firstRunSection)
        WindowRestoration.save(MainRoute(section: .dictation), to: d)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false).section, .dictation)
        WindowRestoration.save(MainRoute(section: .models), to: d)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false).section, MainWindowSpec.firstRunSection, "Models while Advanced is off")
        XCTAssertEqual(WindowRestoration.load(d, advanced: true).section,
                       MainWindowSpec.liveSections.contains(.models) ? .models : MainWindowSpec.firstRunSection)
    }

    /// ⌘1… follow the sidebar, so turning Advanced on shifts the keys after Models.
    func testTheViewMenuKeysFollowTheSwitch() {
        func keys(_ advanced: Bool) -> [String] {
            MainMenuSpec.menu(for: .regular, advanced: advanced, live: all).first { $0.title == .menuView }!.rows.compactMap {
                if case .item(let i) = $0, case .showSection(let s) = i.action { return "\(i.keyEquivalent):\(s.rawValue)" }
                return nil
            }
        }
        let off = keys(false), on = keys(true)
        XCTAssertEqual(off.count, MainWindowSpec.sections(advanced: false, live: all).count)
        XCTAssertEqual(on.count, MainWindowSpec.sections(advanced: true, live: all).count)
        XCTAssertEqual(on.count, off.count + 1, "Models takes a key only while Advanced is on")
        XCTAssertEqual(off.first, "1:speak")
        XCTAssertTrue(on.contains("6:models") && on.contains("7:settings"), "the keys after Models shift: \(on)")
        XCTAssertTrue(off.contains("6:settings"), "\(off)")
    }
}
