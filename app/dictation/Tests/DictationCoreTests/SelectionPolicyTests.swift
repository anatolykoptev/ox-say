import XCTest
@testable import DictationCore

/// The speak-selection capture plan: AX text wins outright; the ⌘C fallback
/// needs a focused non-secure field and a restorable clipboard.
final class SelectionPolicyTests: XCTestCase {

    func testSelectedTextSpeaksDirectly() {
        XCTAssertEqual(SelectionPolicy.plan(axText: "hello", secureInput: false, clipboardRestorable: true),
                       .speak("hello"))
    }

    func testSelectedTextWinsOverEveryBlocker() {
        // Even a secure field or an unrestorable clipboard cannot block a
        // selection AX already handed over — no copy is needed at all.
        XCTAssertEqual(SelectionPolicy.plan(axText: "hi", secureInput: true, clipboardRestorable: false),
                       .speak("hi"))
    }

    func testWhitespaceSelectionIsNotText() {
        XCTAssertEqual(SelectionPolicy.plan(axText: "  \n ", secureInput: false, clipboardRestorable: true),
                       .copy)
    }

    func testNoSelectionFallsBackToCopy() {
        XCTAssertEqual(SelectionPolicy.plan(axText: nil, secureInput: false, clipboardRestorable: true),
                       .copy)
    }

    func testSecureFieldBlocksTheCopy() {
        guard case .decline(let reason) =
                SelectionPolicy.plan(axText: nil, secureInput: true, clipboardRestorable: true) else {
            return XCTFail("a secure field must not see a synthetic ⌘C")
        }
        XCTAssertTrue(reason.contains("password"))
    }

    func testUnrestorableClipboardBlocksTheCopy() {
        guard case .decline =
                SelectionPolicy.plan(axText: nil, secureInput: false, clipboardRestorable: false) else {
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
}
