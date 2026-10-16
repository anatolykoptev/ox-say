import XCTest
@testable import DictationCore

final class MainWindowSpecTests: XCTestCase {
    /// Only Reel and Projects are live in P2; the rest of the model waits
    /// behind the flag for its own phase.
    func testTheSidebarShowsReelAndProjectsOnly() {
        XCTAssertEqual(MainWindowSpec.visibleSections, [.reel, .projects])
        XCTAssertFalse(MainWindowSpec.showsHiddenSections)
    }

    func testTheHiddenSectionsExistInOrderBehindTheFlag() {
        XCTAssertEqual(MainWindowSpec.sections(includeHidden: true),
                       [.reel, .projects, .voices, .dictation, .settings])
        XCTAssertEqual(MainWindowSpec.visibleSections,
                       MainWindowSpec.sections(includeHidden: MainWindowSpec.showsHiddenSections))
    }

    func testEverySectionHasItsStrings() {
        let keys = Set(L10nKey.allCases)
        for section in MainSection.allCases {
            XCTAssertTrue(keys.contains(section.titleKey), "\(section) has a title outside L10nKey")
            XCTAssertTrue(keys.contains(section.placeholderKey), "\(section) has a placeholder outside L10nKey")
        }
    }
}
