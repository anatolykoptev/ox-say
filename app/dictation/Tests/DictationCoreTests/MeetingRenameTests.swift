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

/// #371.4: the rename compares what would be sent (the clamped value), not the raw draft.
final class MeetingRenameClampTests: XCTestCase {
    /// A pasted bidi control is not a change: the daemon would be sent the same title.
    /// Mutation: MeetingRowModel.renamedTitle, compare the raw trimmed `t != shown.trimmed` (no clamp) -> RED.
    func testABidiControlIsNotAChange() {
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "Планёрка\u{202E}", shown: "Планёрка"))
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "\u{2066}Планёрка", shown: "Планёрка\u{2069}"))
        XCTAssertEqual(MeetingRowModel.renamedTitle(draft: "Планёрка\u{202E} 2", shown: "Планёрка"), "Планёрка 2")
    }

    /// A title of only text-direction controls clamps to "": that is no title, not a request to clear the title.
    /// Mutation: MeetingRowModel.renamedTitle, test `t.isEmpty` on the unclamped draft -> RED.
    func testOnlyBidiControlsIsRefusedNotCleared() {
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: "\u{202E}\u{2069}", shown: "Планёрка"))
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: " \u{202A} ", shown: ""))
    }

    /// Cut at the daemon's cap: a draft that differs from the shown title only past the cap is no change.
    func testADifferenceBeyondTheCapIsNotAChange() {
        let base = String(repeating: "a", count: MeetingLimits.titleMax)
        XCTAssertNil(MeetingRowModel.renamedTitle(draft: base + "b", shown: base))
    }
}
