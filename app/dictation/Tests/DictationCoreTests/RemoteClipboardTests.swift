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

    // PasteOutput types instead of borrowing a remote clipboard, so no lease
    // is built over one. If one ever is — a remote copy landing in the gap
    // between the check and the capture — the snapshot must still not go
    // back: it is not a whole copy. Mutation: drop `original.problems` from
    // the restore guard in ClipboardLease.release -> RED.
    func testARemoteSnapshotIsNeverRestored() {
        let board = remoteBoard()
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertEqual(board.text, "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertNotNil(lease.notice, "a remote snapshot is not a whole copy: it must not go back")
        XCTAssertEqual(board.text, "dictated text")
        XCTAssertEqual(board.reads, [])
    }

    // The remote check must look at declared types only: reading data starts
    // the fetch from the other device. Mutation: read the items' data in
    // holdsRemoteCopy -> RED (reads would not be empty).
    func testRemoteDetectionReadsDeclaredTypesOnly() {
        let board = remoteBoard()
        XCTAssertTrue(board.holdsRemoteCopy)
        XCTAssertEqual(board.reads, [])
        XCTAssertFalse(FakePasteboard(text: "local copy").holdsRemoteCopy)
    }

    // #158.5: the one reachable way to a lease over a remote copy (it lands between PasteOutput's declared-type check
    // and the capture) tells the user why, in their language. Mutation: PasteboardSnapshot.capture, delete
    // `snapshot.report(.otherDevice)` -> RED (the notice is gone, the clipboard is silently not put back).
    func testALeaseOverARemoteCopyNamesTheOtherDeviceInBothLanguages() {
        for (locale, phrase) in [("en", "another device"), ("ru", "другого устройства")] {
            let lease = ClipboardLease(board: remoteBoard(), text: "dictated text")
            XCTAssertFalse(lease.release(text: ShippedStrings.localizer(locale)))
            XCTAssertTrue(lease.notice?.contains(phrase) ?? false, "\(locale): \(lease.notice ?? "nil")")
        }
    }

    // #158 (1): a multi-item copy can carry the marker on any item, not only
    // the first. Mutation: ClipboardLease.swift `declaredItems.contains { ... }`
    // -> `declaredItems.first?.contains(where: ...) ?? false` -> RED.
    func testTheMarkerOnALaterItemStillCountsAsRemote() {
        let board = FakePasteboard(text: "first item")
        board.items.append([("public.utf8-plain-text", Data("second".utf8)),
                            (remoteType, Data())])
        XCTAssertTrue(board.holdsRemoteCopy)
        let snapshot = PasteboardSnapshot.capture(board)
        XCTAssertTrue(snapshot.isRemote)
        XCTAssertEqual(board.reads, [], "no item's data is read once any item is remote")
    }

    // #158 (2): after a lease over a remote clipboard the plain write is not
    // repeated: release leaves the board exactly as our one write made it.
    // Mutation: ClipboardLease.release, drop `original.problems` from the
    // guard -> RED (restore writes a second time and clears the contents).
    func testNoPlainWriteFollowsAKeptRemoteClipboard() {
        let board = remoteBoard()
        let lease = ClipboardLease(board: board, text: "dictated text")
        let afterOurWrite = board.changeCount
        let items = board.declaredItems
        XCTAssertFalse(lease.release())
        XCTAssertEqual(board.changeCount, afterOurWrite, "release must not write after a kept remote clipboard")
        XCTAssertEqual(board.declaredItems, items)
        XCTAssertFalse(lease.release(), "a second call is no more able to write")
        XCTAssertEqual(board.changeCount, afterOurWrite)
    }

    // The declared types are read once per capture: a remote copy landing
    // between a check and the enumeration must not get its marker type's data
    // read (the fetch from the phone) or stored for a restore.
    // Mutation: PasteboardSnapshot.capture, ask `board.declaredItems` a second
    // time for the enumeration -> RED.
    func testCaptureAsksTheDeclaredTypesOnce() {
        final class Shifting: DictationPasteboard {
            var asked = 0
            var reads: [String] = []
            var changeCount: Int { 0 }
            var declaredItems: [[String]] {
                asked += 1
                return asked == 1 ? [["public.utf8-plain-text"]]
                                  : [["public.utf8-plain-text", PasteboardMarker.remoteClipboard]]
            }
            func data(item: Int, forType type: String) -> Data? { reads.append(type); return Data("x".utf8) }
            func writeText(_ text: String) -> Int { 0 }
            func restore(_ snapshot: PasteboardSnapshot) {}
        }
        let board = Shifting()
        let snapshot = PasteboardSnapshot.capture(board)
        XCTAssertEqual(board.asked, 1)
        XCTAssertFalse(board.reads.contains(PasteboardMarker.remoteClipboard))
        XCTAssertFalse(snapshot.items.joined().contains { $0.type == PasteboardMarker.remoteClipboard })
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
        XCTAssertEqual(board.text, "the user's copy")
    }
}
