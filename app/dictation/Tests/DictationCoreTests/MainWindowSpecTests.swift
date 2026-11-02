import XCTest
@testable import DictationCore

final class MainWindowSpecTests: XCTestCase {
    /// The sections with nothing behind them yet stay out of the sidebar, and the Advanced switch stays undrawn.
    func testTheSidebarShowsTheLiveSectionsInSidebarOrder() {
        XCTAssertEqual(MainWindowSpec.sections(advanced: false), [.voices, .dictation, .meetings, .settings])
        XCTAssertEqual(MainWindowSpec.sections(advanced: true), MainWindowSpec.sections(advanced: false),
                       "Models is not live yet, so the switch changes nothing")
        XCTAssertFalse(MainWindowSpec.showsAdvancedSwitch)
        XCTAssertEqual(MainWindowSpec.firstRunSection, .meetings, "Voiceover is not live yet")
    }

    func testEverySectionHasItsStrings() {
        let keys = Set(L10nKey.allCases)
        for section in MainSection.allCases {
            XCTAssertTrue(keys.contains(section.titleKey), "\(section) has a title outside L10nKey")
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
        for section in MainWindowSpec.sections(advanced: true) {
            XCTAssertEqual(MainWindowSpec.subtitleKey(for: section), section.titleKey)
            XCTAssertNotEqual(MainWindowSpec.windowTitleKey, MainWindowSpec.subtitleKey(for: section))
        }
    }
}
