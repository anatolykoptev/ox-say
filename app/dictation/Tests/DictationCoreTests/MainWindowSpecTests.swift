import XCTest
@testable import DictationCore

final class MainWindowSpecTests: XCTestCase {
    /// Meetings first, then Dictation, Voices and Settings; Reel and Projects have nothing behind
    /// them and stay out of the sidebar.
    func testTheSidebarShowsTheFourLiveSections() {
        XCTAssertEqual(MainWindowSpec.visibleSections, [.meetings, .dictation, .voices, .settings])
        XCTAssertFalse(MainWindowSpec.showsPlannedSections)
    }

    func testThePlannedSectionsExistInOrderBehindTheFlag() {
        XCTAssertEqual(MainWindowSpec.sections(includePlanned: true),
                       [.meetings, .dictation, .voices, .settings, .reel, .projects])
        XCTAssertEqual(MainWindowSpec.visibleSections,
                       MainWindowSpec.sections(includePlanned: MainWindowSpec.showsPlannedSections))
    }

    func testEverySectionHasItsStrings() {
        let keys = Set(L10nKey.allCases)
        for section in MainSection.allCases {
            XCTAssertTrue(keys.contains(section.titleKey), "\(section) has a title outside L10nKey")
            if let placeholder = section.placeholderKey {
                XCTAssertTrue(keys.contains(placeholder), "\(section) has a placeholder outside L10nKey")
            }
            XCTAssertEqual(section.placeholderKey != nil, section.isPlanned, "only planned sections carry a placeholder")
        }
    }
}
