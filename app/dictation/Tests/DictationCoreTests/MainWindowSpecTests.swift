import SwiftUI
import XCTest
@testable import DictationCore

final class MainWindowSpecTests: XCTestCase {
    /// The sections with nothing behind them yet stay out of the sidebar, and the Advanced switch stays undrawn.
    func testTheSidebarShowsTheLiveSectionsInSidebarOrder() {
        XCTAssertEqual(MainWindowSpec.sections(advanced: false), [.speak, .voices, .dictation, .meetings, .settings])
        XCTAssertEqual(MainWindowSpec.sections(advanced: true), MainWindowSpec.sections(advanced: false),
                       "Models is not live yet, so the switch changes nothing")
        XCTAssertFalse(MainWindowSpec.showsAdvancedSwitch)
        XCTAssertEqual(MainWindowSpec.firstRunSection, .speak, "Voiceover is live")
    }

    /// The window floor leaves room for the widest sidebar (240), the Meetings list at its least (260), the divider (1) and the
    /// meeting at its least (300): 801, so the meeting pane is never clipped. The literals are the oracle, not the constants.
    /// Mutation: MainWindowSpec.minimumWidth back to a literal 760 -> RED.
    func testTheWindowFloorFitsTheWidestSidebarAndTheMeetingsSplitAtTheirLeast() {
        XCTAssertGreaterThanOrEqual(MainWindowSpec.minimumWidth, 240 + 260 + 1 + 300)
        XCTAssertEqual(MainWindowSpec.sidebarWidth.maximum, 240)
        XCTAssertEqual(MainWindowSpec.meetingsListWidth.minimum, 260)
        XCTAssertEqual(MainWindowSpec.meetingsListWidth.maximum, 420)
        XCTAssertEqual(MainWindowSpec.meetingsDetailMinimum, 300)
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

    // N4 review: the arrow keys cross between the sections list and the one-row Settings list only when they are bare.
    private let nav: [MainSection] = [.speak, .voices, .dictation, .meetings, .settings]

    func testBareDownOnTheLastSectionReachesSettingsAndBareUpReturns() {
        XCTAssertEqual(MainWindowSpec.sidebarMove(.down, from: .sections, plain: true, current: .meetings, sections: nav),
                       SidebarMove(section: .settings, list: .settings))
        XCTAssertEqual(MainWindowSpec.sidebarMove(.up, from: .settings, plain: true, current: .settings, sections: nav),
                       SidebarMove(section: .meetings, list: .sections))
    }

    /// Cmd/Shift/Option-Down on the last section is the list's own (extend, jump), never the hop to Settings.
    /// Mutation: MainWindowSpec.sidebarMove, delete `guard plain else { return nil }` -> RED.
    func testAnArrowWithAModifierNeverCrossesLists() {
        XCTAssertNil(MainWindowSpec.sidebarMove(.down, from: .sections, plain: false, current: .meetings, sections: nav))
        XCTAssertNil(MainWindowSpec.sidebarMove(.up, from: .settings, plain: false, current: .settings, sections: nav))
    }

    func testOtherArrowsAndPositionsStayWithTheList() {
        XCTAssertNil(MainWindowSpec.sidebarMove(.down, from: .sections, plain: true, current: .voices, sections: nav))
        XCTAssertNil(MainWindowSpec.sidebarMove(.up, from: .sections, plain: true, current: .meetings, sections: nav))
        XCTAssertNil(MainWindowSpec.sidebarMove(.down, from: .settings, plain: true, current: .settings, sections: nav))
        // No Settings row, no hop.
        XCTAssertNil(MainWindowSpec.sidebarMove(.down, from: .sections, plain: true, current: .meetings,
                                                sections: [.speak, .meetings]))
    }

    /// A real hardware arrow carries `.numericPad` and `.function`; those are not held modifiers.
    /// Mutation: SidebarArrow.isPlain, `modifiers.isDisjoint(with: [...])` -> `modifiers.isEmpty` -> RED.
    func testTheFlagsOfARealArrowKeyStillCountAsPlain() {
        XCTAssertTrue(SidebarArrow.isPlain([]))
        XCTAssertTrue(SidebarArrow.isPlain([.numericPad]))
        XCTAssertTrue(SidebarArrow.isPlain([.function]))
        XCTAssertTrue(SidebarArrow.isPlain([.numericPad, .function]))
        for held: EventModifiers in [.shift, .control, .option, .command] {
            XCTAssertFalse(SidebarArrow.isPlain(held))
            XCTAssertFalse(SidebarArrow.isPlain([held, .numericPad, .function]))
        }
    }
}
