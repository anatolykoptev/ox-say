import XCTest
@testable import DictationCore

/// A Universal Clipboard copy (made on another device) declares
/// `com.apple.is-remote-clipboard`; reading any of its types makes macOS fetch the
/// contents from the other device, which shows a panel and stalls the paste.
final class RemoteClipboardTests: XCTestCase {
    private let remoteType = PasteboardMarker.remoteClipboard

    private func remoteBoard() -> FakePasteboard {
        let board = FakePasteboard(text: "copied on the iPhone")
        board.items[0].append((type: "public.rtf", data: Data("rtf".utf8)))
        board.items[0].append((type: remoteType, data: Data()))
        return board
    }

    // Mutation: delete the `isRemote` early return in PasteboardSnapshot.capture
    // -> RED (every type is read, which starts the fetch from the phone).
    func testCaptureOfARemoteClipboardReadsNoData() {
        let board = remoteBoard()
        let snapshot = PasteboardSnapshot.capture(board)
        XCTAssertEqual(board.reads, [], "reading a remote type starts the fetch from the other device")
        XCTAssertTrue(snapshot.isRemote)
        XCTAssertFalse(snapshot.problems.isEmpty, "a snapshot without the data must not be restorable")
    }

    // Mutation: make ClipboardLease.release skip the `original.isRemote` guard
    // -> RED (the notice is shown on every dictation after an iPhone copy).
    func testRemoteClipboardLeavesTheDictationWithoutANotice() {
        let board = remoteBoard()
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertEqual(board.text, "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertNil(lease.notice, "a notice per dictation after an iPhone copy is noise")
        XCTAssertTrue(lease.keptRemote)
        XCTAssertEqual(board.text, "dictated text")
        XCTAssertEqual(board.reads, [])
    }

    // Mutation: return `items` instead of the filtered list from
    // PasteboardSnapshot.restorableItems -> RED (the restored clipboard still
    // looks remote, and every later dictation hits the fetch again).
    func testRestoreNeverWritesTheRemoteMarkerBack() {
        let snapshot = PasteboardSnapshot(items: [[
            PasteboardEntry(type: "public.utf8-plain-text", data: Data("a".utf8)),
            PasteboardEntry(type: remoteType, data: Data()),
        ]])
        let board = FakePasteboard(text: "x")
        board.restore(snapshot)
        XCTAssertFalse(board.declaredItems.joined().contains(remoteType))
        XCTAssertEqual(board.text, "a")
    }

    // Regression guard for the existing path: the remote check must not touch
    // a normal clipboard.
    func testANormalClipboardIsStillReadAndRestored() {
        let board = FakePasteboard(text: "the user's copy")
        let snapshot = PasteboardSnapshot.capture(board)
        XCTAssertFalse(snapshot.isRemote)
        XCTAssertEqual(board.reads, ["public.utf8-plain-text"])
        let lease = ClipboardLease(board: board, text: "dictated")
        XCTAssertTrue(lease.release())
        XCTAssertFalse(lease.keptRemote)
        XCTAssertEqual(board.text, "the user's copy")
    }
}
