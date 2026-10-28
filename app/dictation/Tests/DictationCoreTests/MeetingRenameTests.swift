import Foundation
import XCTest
@testable import DictationCore

/// The rename field starts with the title the window SHOWS (an auto title is localized there). Saving it unchanged must
/// not turn "Zoom call" into the user's own title in whatever language the window happened to be in (#270).
final class MeetingRenameTests: XCTestCase {
    /// Mutation: MeetingRowModel.renamedTitle, drop the `trimmed == shown` guard -> RED.
    func testAnUntouchedDraftSavesNothing() {
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "Звонок Zoom", shown: "Звонок Zoom"))
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "  Звонок Zoom ", shown: "Звонок Zoom"))
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "   ", shown: "Звонок Zoom"), "an empty title is not a title")
        XCTAssertEqual(MeetingRowModel.renamedTitle(draft: " Планёрка ", shown: "Звонок Zoom"), "Планёрка")
    }
}
