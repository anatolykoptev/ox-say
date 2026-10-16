import XCTest
@testable import DictationCore

final class WindowPolicyTests: XCTestCase {
    private func window(_ kind: WindowKind, canBecomeMain: Bool = true, visible: Bool = true) -> WindowDescription {
        WindowDescription(kind: kind, canBecomeMain: canBecomeMain, visible: visible)
    }

    func testTheMainWindowOpenMakesTheAppRegular() {
        XCTAssertEqual(WindowPolicy.policy(for: [window(.main)]), .regular)
    }

    func testNoWindowsKeepsTheAppAnAccessory() {
        XCTAssertEqual(WindowPolicy.policy(for: []), .accessory)
    }

    /// The about panel, the review sheet and the overlay pill all worked under
    /// .accessory before the main window existed, and each activates the app
    /// itself when it needs to. None of them is a reason for a Dock icon — even
    /// one that claims it can become main.
    func testAuxiliaryWindowsNeverHoldTheDockIcon() {
        for kind in [WindowKind.overlay, .panel] {
            XCTAssertEqual(WindowPolicy.policy(for: [window(kind)]), .accessory,
                           "\(kind) alone must not keep the app .regular")
        }
    }

    /// windowWillClose is answered after the window left NSApp.windows; a
    /// listed-but-ordered-out main window is the halfway state.
    func testTheMainWindowClosedWhileAnotherPanelIsOpenReturnsToAccessory() {
        XCTAssertEqual(WindowPolicy.policy(for: [window(.main, visible: false), window(.panel)]), .accessory)
    }

    func testAWindowThatCannotBecomeMainNeverCounts() {
        XCTAssertEqual(WindowPolicy.policy(for: [window(.main, canBecomeMain: false)]), .accessory)
        XCTAssertEqual(WindowPolicy.policy(for: [window(.main, canBecomeMain: false), window(.panel)]), .accessory)
    }

    func testTheMainWindowBesideAuxiliaryOnesStillHoldsRegular() {
        XCTAssertEqual(WindowPolicy.policy(for: [window(.panel), window(.overlay), window(.main)]), .regular)
    }
}
