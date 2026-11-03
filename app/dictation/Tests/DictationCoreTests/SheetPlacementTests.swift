import CoreGraphics
import XCTest
@testable import DictationCore

/// Shots composites a sheet window onto its parent's capture. `screencapture -l` of the parent omits the sheet, so the
/// sheet's image is drawn at its on-screen offset; a wrong offset puts the sheet in the wrong place or off the shot.
final class SheetPlacementTests: XCTestCase {
    /// Screen coordinates: origin bottom-left, y up. A sheet hangs from the parent's top edge, 100 pt in from the left.
    func testSheetHangingFromTheTopEdgeSitsAtTheTopOfTheImage() {
        let main = CGRect(x: 60, y: 60, width: 980, height: 680)
        let sheet = CGRect(x: 60 + 270, y: 60 + 680 - 400, width: 440, height: 400)
        let r = SheetPlacement.rect(main: main, sheet: sheet, scale: 1)
        XCTAssertEqual(r, CGRect(x: 270, y: 280, width: 440, height: 400))
        // In the image's own top-left terms the sheet starts at the very top.
        XCTAssertEqual(SheetPlacement.topLeftY(of: r, imageHeight: 680), 0)
    }

    func testRetinaScalesOffsetAndSizeAlike() {
        let main = CGRect(x: 100, y: 200, width: 980, height: 680)
        let sheet = CGRect(x: 370, y: 480, width: 440, height: 400)
        let r = SheetPlacement.rect(main: main, sheet: sheet, scale: 2)
        XCTAssertEqual(r, CGRect(x: 540, y: 560, width: 880, height: 800))
    }

    func testTheMainWindowsOwnOriginDoesNotMatter() {
        let a = SheetPlacement.rect(main: CGRect(x: 0, y: 0, width: 500, height: 300),
                                    sheet: CGRect(x: 50, y: 40, width: 100, height: 80), scale: 1)
        let b = SheetPlacement.rect(main: CGRect(x: -1500, y: 900, width: 500, height: 300),
                                    sheet: CGRect(x: -1450, y: 940, width: 100, height: 80), scale: 1)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.origin.x != 0 && a.origin.y != 0)
    }
}
