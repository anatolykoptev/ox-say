import XCTest
@testable import DictationCore

final class DictationHistoryTests: XCTestCase {
    func testKeepsNewestFirst() {
        let history = DictationHistory()
        history.add("one"); history.add("two"); history.add("three")
        XCTAssertEqual(history.texts, ["three", "two", "one"])
        XCTAssertEqual(history.latest, "three")
    }

    func testKeepsOnlyTheLastTen() {
        let history = DictationHistory()
        for n in 1...12 { history.add("d\(n)") }
        XCTAssertEqual(history.texts.count, 10)
        XCTAssertEqual(history.texts.first, "d12")
        XCTAssertEqual(history.texts.last, "d3", "the two oldest fall off")
    }

    func testEmptyAndBlankTextIsNotADictation() {
        let history = DictationHistory()
        history.add(""); history.add("  \n\t ")
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.latest)
    }

    func testALongTextKeepsItsFullTextAndGetsAShortTitle() {
        let history = DictationHistory()
        let long = String(repeating: "word ", count: 40)
        history.add(long)
        XCTAssertEqual(history.texts, [long], "copy and paste need the whole dictation")
        let title = history.titles[0]
        XCTAssertEqual(title.count, DictationHistory.titleLimit)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testAShortTextIsItsOwnTitleOnOneLine() {
        XCTAssertEqual(DictationHistory.title(for: "hello\n  world"), "hello world")
    }

    func testTheMenuListsOneCopyRowPerDictationNewestFirst() {
        let history = DictationHistory()
        history.add("first"); history.add("second")
        XCTAssertEqual(RecentDictationsMenu.rows(history: history), [
            .item(title: "second", isOn: false, isEnabled: true, action: .copyDictation(0)),
            .item(title: "first", isOn: false, isEnabled: true, action: .copyDictation(1)),
        ])
        XCTAssertTrue(RecentDictationsMenu.isEnabled(history: history))
    }

    func testTheMenuIsDisabledWhileEmpty() {
        let history = DictationHistory()
        XCTAssertEqual(RecentDictationsMenu.rows(history: history), [])
        XCTAssertFalse(RecentDictationsMenu.isEnabled(history: history))
    }
}

final class DictationHistoryHookTests: XCTestCase {
    @MainActor private func dictate(_ delivery: Delivery, text: String) async -> DictationController {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput(); out.delivery = delivery
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in text }
        c.keyDown(); c.keyUp()
        let deadline = Date().addingTimeInterval(2)
        while c.state != .idle && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return c
    }

    @MainActor
    func testAPastedDictationEntersTheHistory() async {
        let c = await dictate(.paste, text: "pasted words")
        XCTAssertEqual(c.history.texts, ["pasted words"])
    }

    // Mutation: in DictationController.finish, add to the history only when the
    // delivery is `.paste` (skip it for a clipboard-only delivery) -> RED here.
    @MainActor
    func testAClipboardOnlyDictationEntersTheHistoryToo() async {
        let c = await dictate(.clipboardOnly(reason: .secureInput), text: "kept words")
        XCTAssertEqual(c.history.texts, ["kept words"], "the history must not depend on the paste outcome")
    }

    @MainActor
    func testAnEmptyTranscriptionLeavesTheHistoryAlone() async {
        let c = await dictate(.paste, text: "")
        XCTAssertTrue(c.history.isEmpty)
    }
}

final class PasteSettlementTests: XCTestCase {
    private struct Calls {
        var settled: [Bool] = []
        var remoteKept = 0
        var notices: [String] = []
        var unread = 0
    }

    private func settle(_ board: FakePasteboard, lease: ClipboardLease, read: Bool) -> Calls {
        var calls = Calls()
        PasteSettlement.settle(lease: lease, text: "dictated text", read: read, plain: board,
                               onSettled: { calls.settled.append($0) },
                               onRemoteClipboardKept: { calls.remoteKept += 1 },
                               onNotice: { calls.notices.append($0) },
                               onUnread: { calls.unread += 1 })
        return calls
    }

    // Mutation: delete the `onUnread?()` call in PasteSettlement.settle -> RED
    // (journey 1: the paste lands nowhere and the user hears nothing).
    func testAnUnreadPasteWithTheClipboardRestoredRaisesTheUnreadNotice() {
        let board = FakePasteboard(text: "the user's copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        let calls = settle(board, lease: lease, read: false)
        XCTAssertEqual(calls.unread, 1, "an unread paste whose clipboard went back must tell the user")
        XCTAssertEqual(calls.settled, [false])
    }

    // Journey 3: read=no can be a false negative; the user's clipboard stays theirs.
    func testAnUnreadPasteNeverOverwritesTheUsersClipboard() {
        let board = FakePasteboard(text: "the user's copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        _ = settle(board, lease: lease, read: false)
        XCTAssertEqual(board.text, "the user's copy", "read=no must not put the dictation on the clipboard")
    }

    func testAReadPasteRestoresQuietly() {
        let board = FakePasteboard(text: "the user's copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        let calls = settle(board, lease: lease, read: true)
        XCTAssertEqual(calls.unread, 0)
        XCTAssertEqual(calls.notices, [])
        XCTAssertEqual(board.text, "the user's copy")
    }

    func testAClipboardThatCouldNotBeRestoredKeepsTheTextAndSaysWhy() {
        let board = FakePasteboard(text: "")
        board.items = [[("public.png", Data(repeating: 0, count: PasteboardSnapshot.maxBytes + 1))]]
        let lease = ClipboardLease(board: board, text: "dictated text")
        let calls = settle(board, lease: lease, read: false)
        XCTAssertEqual(board.text, "dictated text")
        XCTAssertEqual(calls.notices.count, 1)
        XCTAssertEqual(calls.unread, 0, "the dictation is on the clipboard: nothing is lost, one notice is enough")
    }

    func testAUserCopyMadeMeanwhileIsLeftAlone() {
        let board = FakePasteboard(text: "old")
        let lease = ClipboardLease(board: board, text: "dictated text")
        board.userCopies("new")
        let calls = settle(board, lease: lease, read: false)
        XCTAssertEqual(board.text, "new")
        XCTAssertEqual(calls.unread, 0)
    }
}
