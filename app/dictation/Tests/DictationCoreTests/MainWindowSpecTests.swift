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

    /// F1: the Space behaviour is one pure value the window takes at its single creation site. Apple's header allows one of the
    /// Space bits and one of the full-screen bits: MoveToActiveSpace (the window comes to the user's Space) with FullScreenAuxiliary
    /// (that Space may be another app's full-screen one).
    func testTheWindowComesToTheCurrentSpaceEvenAFullScreenOne() {
        let b = MainWindowSpec.collectionBehavior
        XCTAssertTrue(b.contains(.moveToActiveSpace))
        XCTAssertTrue(b.contains(.fullScreenAuxiliary))
        XCTAssertFalse(b.contains(.canJoinAllSpaces), "exclusive with moveToActiveSpace")
        XCTAssertFalse(b.contains(.fullScreenPrimary), "exclusive with fullScreenAuxiliary")
        XCTAssertFalse(b.contains(.fullScreenNone), "exclusive with fullScreenAuxiliary")
        XCTAssertFalse(b.contains(.stationary), "the window stays movable and minimisable")
        XCTAssertFalse(b.contains(.transient))
    }

    /// F5: the window is one "OxSay"; the section is the subtitle.
    func testTheWindowTitleIsTheAppAndTheSectionIsTheSubtitle() {
        XCTAssertEqual(MainWindowSpec.windowTitleKey, .windowTitle)
        for section in MainWindowSpec.visibleSections {
            XCTAssertEqual(MainWindowSpec.subtitleKey(for: section), section.titleKey)
            XCTAssertNotEqual(MainWindowSpec.windowTitleKey, MainWindowSpec.subtitleKey(for: section))
        }
    }
}
