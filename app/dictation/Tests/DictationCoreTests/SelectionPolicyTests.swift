import XCTest
@testable import DictationCore

/// The speak-selection capture plan: AX text wins outright; the ⌘C fallback
/// needs a focused non-secure field and a restorable clipboard.
final class SelectionPolicyTests: XCTestCase {

    func testSelectedTextSpeaksDirectly() {
        XCTAssertEqual(SelectionPolicy.plan(axText: "hello", secureInput: false, clipboardRestorable: true,
                                            clipboardRemote: false),
                       .speak("hello"))
    }

    func testSelectedTextWinsOverEveryBlocker() {
        // Even a secure field or an unrestorable clipboard cannot block a
        // selection AX already handed over — no copy is needed at all.
        XCTAssertEqual(SelectionPolicy.plan(axText: "hi", secureInput: true, clipboardRestorable: false,
                                            clipboardRemote: true),
                       .speak("hi"))
    }

    func testWhitespaceSelectionIsNotText() {
        XCTAssertEqual(SelectionPolicy.plan(axText: "  \n ", secureInput: false, clipboardRestorable: true,
                                            clipboardRemote: false),
                       .copy)
    }

    func testNoSelectionFallsBackToCopy() {
        XCTAssertEqual(SelectionPolicy.plan(axText: nil, secureInput: false, clipboardRestorable: true,
                                            clipboardRemote: false),
                       .copy)
    }

    func testSecureFieldBlocksTheCopy() {
        guard case .decline(let reason) =
                SelectionPolicy.plan(axText: nil, secureInput: true, clipboardRestorable: true,
                                     clipboardRemote: false) else {
            return XCTFail("a secure field must not see a synthetic ⌘C")
        }
        XCTAssertTrue(reason.contains("password"))
    }

    func testUnrestorableClipboardBlocksTheCopy() {
        guard case .decline =
                SelectionPolicy.plan(axText: nil, secureInput: false, clipboardRestorable: false,
                                     clipboardRemote: false) else {
            return XCTFail("a clipboard that cannot be restored must not be copied over")
        }
    }

    // Mutation: SelectionPolicy.plan `guard clipboardRestorable || clipboardRemote`
    // -> `guard clipboardRestorable` -> RED (speak-selection stops working
    // whenever the clipboard holds an iPhone copy and AX gives nothing).
    func testRemoteClipboardStillCopies() {
        XCTAssertEqual(SelectionPolicy.plan(axText: nil, secureInput: false,
                                            clipboardRestorable: false, clipboardRemote: true),
                       .copy)
    }

    func testSecureFieldStillBlocksTheCopyOverARemoteClipboard() {
        guard case .decline = SelectionPolicy.plan(axText: nil, secureInput: true,
                                                   clipboardRestorable: false, clipboardRemote: true) else {
            return XCTFail("a secure field must not see a synthetic ⌘C, remote clipboard or not")
        }
    }

    // needsClipboard tells the caller when the plan's clipboard inputs matter;
    // if it drifts from plan's own order, the snapshot is skipped exactly when
    // it was needed and the borrow can never be planned.
    // Mutation: needsClipboard, `return true` unconditionally -> RED in
    // SelectionBorrowTests.testAXTextIsSpokenWithoutTouchingTheClipboard (the
    // clipboard is read on the AX path). `return false` -> RED in
    // testAnEmptyAXFallsBackToTheClipboardBorrow.
    func testNeedsClipboardMatchesWhereThePlanLooks() {
        XCTAssertFalse(SelectionPolicy.needsClipboard(axText: "text", secureInput: false))
        XCTAssertFalse(SelectionPolicy.needsClipboard(axText: "text", secureInput: true),
                       "AX wins over a secure field too: no clipboard is ever needed")
        XCTAssertFalse(SelectionPolicy.needsClipboard(axText: nil, secureInput: true),
                       "a secure field declines before the clipboard is looked at")
        XCTAssertTrue(SelectionPolicy.needsClipboard(axText: nil, secureInput: false))
        XCTAssertTrue(SelectionPolicy.needsClipboard(axText: "  ", secureInput: false))
    }

    // The equivalence itself: wherever needsClipboard says no, the plan's
    // answer must not change with the clipboard inputs.
    func testWhereTheClipboardIsNotNeededItsFlagsDoNotMatter() {
        for ax in [nil, "", "x"] {
            for secure in [false, true] where !SelectionPolicy.needsClipboard(axText: ax, secureInput: secure) {
                XCTAssertEqual(
                    SelectionPolicy.plan(axText: ax, secureInput: secure,
                                         clipboardRestorable: false, clipboardRemote: false),
                    SelectionPolicy.plan(axText: ax, secureInput: secure,
                                         clipboardRestorable: true, clipboardRemote: true),
                    "ax=\(String(describing: ax)) secure=\(secure): the plan looked at a clipboard it was said not to need")
            }
        }
    }
}
