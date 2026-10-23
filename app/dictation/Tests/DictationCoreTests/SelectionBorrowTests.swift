import XCTest
@testable import DictationCore

/// The speak-selection capture over fake seams: AX is asked first and the
/// clipboard is borrowed only when the policy allows. A fake ⌘C is the app's
/// copy landing — `board.userCopies` is what the frontmost app would write.
final class SelectionBorrowTests: XCTestCase {
    private func remoteBoard() -> FakePasteboard {
        let board = FakePasteboard(text: "copied on the iPhone")
        board.items[0].append((type: "public.rtf", data: Data("rtf".utf8)))
        board.items[0].append((type: PasteboardMarker.remoteClipboard, data: Data()))
        return board
    }

    // AX hands over the selection: nothing is copied, and the clipboard is not
    // touched at all — the whole point for a Universal Clipboard copy, which a
    // mere snapshot read already cannot restore but must not provoke either.
    // Mutation: SelectionBorrow.capture, always send ⌘C (drop the AX-first
    // plan) -> RED (postCopy fires, the clipboard is written and restored).
    func testAXTextIsSpokenWithoutTouchingTheClipboard() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { "the selection" },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1 },
                                                    spin: { _ in },
                                                    readText: { board.text })
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 0, "AX handed the selection over: ⌘C must never be sent")
        XCTAssertEqual(board.changeCount, 0, "the clipboard is not written at all")
        XCTAssertEqual(board.reads, [], "the clipboard is not even read")
    }

    // AX gave nothing: the clipboard is borrowed, ⌘C reads the selection, and
    // the user's own copy goes back.
    // Mutation: SelectionBorrow.capture, delete the `.copy` branch (decline
    // instead of borrowing) -> RED.
    func testAnEmptyAXFallsBackToTheClipboardBorrow() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { nil },
                                                    secureInput: { false },
                                                    postCopy: { copies += 1; board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text })
        XCTAssertEqual(text, "the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(board.text, "the user's copy", "the borrow puts the user's copy back")
    }

    // Anchored wiring: the remote flag the snapshot finds must reach the plan.
    // With `clipboardRemote: false` at the call site, an iPhone copy's snapshot
    // reads "unrestorable" and the borrow is declined — speak-selection stops
    // working after every iPhone copy, exactly #214's symptom.
    // Mutation: SelectionBorrow.capture, `clipboardRemote: snapshot?.isRemote
    // ?? false` -> `clipboardRemote: false` -> RED.
    func testTheRemoteFlagReachesThePlan() {
        let board = remoteBoard()
        var remoteCopies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { nil },
                                                    secureInput: { false },
                                                    postCopy: { board.userCopies("the selection") },
                                                    spin: { _ in },
                                                    readText: { board.text },
                                                    onRemoteCopy: { remoteCopies += 1 })
        XCTAssertEqual(text, "the selection", "⌘C over a remote copy still reads the selection")
        XCTAssertNil(problem)
        XCTAssertEqual(remoteCopies, 1, "a ⌘C landing over a remote copy is logged once")
        XCTAssertEqual(board.text, "the selection",
                       "a remote snapshot is never restored: the clipboard keeps the copy")
        XCTAssertEqual(board.reads, [], "the remote copy's data is never read")
    }

    // The other side of the same line: ⌘C lands nothing, so the remote copy
    // was never overwritten and nothing is logged.
    func testARemoteClipboardWithNoCopyComingNeedsNoLog() {
        let board = remoteBoard()
        var remoteCopies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { nil },
                                                    secureInput: { false },
                                                    postCopy: {},
                                                    spin: { _ in },
                                                    readText: { board.text },
                                                    onRemoteCopy: { remoteCopies += 1 })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "Nothing selected to speak.")
        XCTAssertEqual(remoteCopies, 0, "the remote copy survived: there is nothing to log")
        XCTAssertTrue(board.declaredItems.joined().contains(PasteboardMarker.remoteClipboard),
                      "a selection-less ⌘C writes nothing: the iPhone copy is still there")
    }

    // A secure field gets neither AX nor ⌘C — the decline comes before any
    // clipboard contact.
    func testASecureFieldDeclinesWithoutTouchingTheClipboard() {
        let board = FakePasteboard(text: "the user's copy")
        var copies = 0
        let (text, problem) = SelectionBorrow.capture(board: board,
                                                    selectedText: { nil },
                                                    secureInput: { true },
                                                    postCopy: { copies += 1 },
                                                    spin: { _ in },
                                                    readText: { board.text })
        XCTAssertNil(text)
        XCTAssertEqual(problem, "A password field is focused.")
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(board.changeCount, 0)
        XCTAssertEqual(board.reads, [])
    }

    // Wiring guard: the app forwards the remote-copy line to the unified log —
    // without it the loss happens silently. Anchored on both source files:
    // SelectionCapture must pass the hook through, AppDelegate must set it.
    func testTheAppWiresTheRemoteCopyLine() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
        let capture = (try? String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/SelectionCapture.swift"),
                                   encoding: .utf8)) ?? ""
        XCTAssertFalse(capture.isEmpty, "SelectionCapture.swift unreadable")
        XCTAssertTrue(capture.contains("onRemoteCopy: onRemoteCopy"),
                      "SelectionCapture drops the remote-copy hook — the fallback is never logged")
        let appDelegate = (try? String(contentsOf: root.appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift"),
                                       encoding: .utf8)) ?? ""
        XCTAssertFalse(appDelegate.isEmpty, "AppDelegate.swift unreadable")
        XCTAssertTrue(appDelegate.contains("capture.onRemoteCopy = {"),
                      "no log line is wired for a ⌘C over a Universal Clipboard copy")
    }
}
