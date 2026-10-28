import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DictationCore

/// A pasteboard whose data takes `delay` seconds to materialise, like a big image copied in Preview.
final class SlowPasteboard: DictationPasteboard {
    let inner: FakePasteboard
    private let delay: TimeInterval
    private let lock = NSLock()
    private var dataCalls = 0
    init(text: String, delay: TimeInterval) { inner = FakePasteboard(text: text); self.delay = delay }
    /// How many times `data(item:forType:)` was called, from any thread.
    var reads: Int { lock.withLock { dataCalls } }
    var changeCount: Int { inner.changeCount }
    var declaredItems: [[String]] { inner.declaredItems }
    func data(item: Int, forType type: String) -> Data? {
        lock.withLock { dataCalls += 1 }
        Thread.sleep(forTimeInterval: delay)
        return inner.data(item: item, forType: type)
    }
    @discardableResult func writeText(_ text: String) -> Int { inner.writeText(text) }
    func restore(_ snapshot: PasteboardSnapshot) { inner.restore(snapshot) }
    var text: String { inner.text }
}

/// The real en/ru strings, for tests that check what a user would read.
enum ShippedStrings {
    static func table(_ locale: String) -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/\(locale).lproj/Localizable.strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }
    static func localizer(_ locale: String) -> (L10nKey) -> String {
        let t = table(locale)
        return { t[$0.rawValue] ?? "MISSING \($0.rawValue)" }
    }
}

final class ClipboardReadLimitTests: XCTestCase {
    /// A clipboard that cannot be read in time is NOT borrowed: nothing is written (a write clears the user's copy with
    /// nothing to put back), the delivery is typed, and the caller is not held past the limit.
    /// Mutation: ClipboardBorrow.take, delete `if original.timedOut { return .typed }` -> RED (the dictated text is
    /// written over the copy).
    func testASlowClipboardIsNeverWrittenOverAndTheTextIsTyped() {
        let board = SlowPasteboard(text: "the user's big copy", delay: 1.5)
        let before = board.inner.items.map { $0.map(\.type) }
        let started = Date()
        let taken = ClipboardBorrow.take(board: board, text: "dictated text", memory: SlowClipboardMemory(),
                                         focusMoved: { false }, readLimit: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the read must not be waited out on the calling thread")
        XCTAssertEqual(taken.delivery, .typed)
        XCTAssertEqual(board.changeCount, 0, "no clear, no write")
        XCTAssertEqual(board.text, "the user's big copy")
        XCTAssertEqual(board.inner.items.map { $0.map(\.type) }, before)
    }

    /// A read that finishes in time still pastes and restores, exactly as before.
    func testAReadInsideTheLimitStillPastesAndRestores() {
        let board = SlowPasteboard(text: "the user's copy", delay: 0.01)
        guard case .lease(let lease) = ClipboardBorrow.take(board: board, text: "dictated text", memory: SlowClipboardMemory(),
                                                       focusMoved: { false }, readLimit: 5) else {
            return XCTFail("a clipboard read in time is borrowed")
        }
        XCTAssertEqual(ClipboardBorrow.lease(lease).delivery, .paste)
        XCTAssertEqual(board.text, "dictated text", "the text is on the clipboard for the paste")
        XCTAssertTrue(lease.release())
        XCTAssertEqual(board.text, "the user's copy")
        XCTAssertNil(lease.notice)
    }

    /// The timeout snapshot is not a whole copy and carries no invented problem.
    func testTheTimeoutSnapshotIsNotWhole() {
        let board = SlowPasteboard(text: "x", delay: 1.0)
        let snapshot = PasteboardSnapshot.capture(board, timeLimit: 0.05)
        XCTAssertTrue(snapshot.timedOut)
        XCTAssertFalse(snapshot.isWhole)
        XCTAssertTrue(snapshot.items.isEmpty)
        let unbounded = PasteboardSnapshot.capture(SlowPasteboard(text: "x", delay: 0.01), timeLimit: nil)
        XCTAssertTrue(unbounded.isWhole)
        XCTAssertFalse(unbounded.timedOut)
    }

    /// After the timeout the abandoned read stops asking the board for data: at most the call already in flight ends.
    /// Mutation: PasteboardSnapshot.capture, delete `guard shouldContinue() else { break capture }` -> RED (it reads on).
    func testAnAbandonedReadStopsAskingForData() {
        let board = SlowPasteboard(text: "x", delay: 0.25)
        board.inner.items = [(0..<8).map { (type: "public.type\($0)", data: Data("d".utf8) as Data?) }]
        let snapshot = PasteboardSnapshot.capture(board, timeLimit: 0.1)
        XCTAssertTrue(snapshot.timedOut)
        let atTimeout = board.reads
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertLessThanOrEqual(board.reads - atTimeout, 1, "reads after the cancel: \(board.reads - atTimeout)")
    }

    /// The speak-selection path takes its snapshot through the limit and a timed-out one is not restorable (the copy
    /// is declined, ⌘C is never sent). Mutation: SelectionBorrow.run, `$0.isWhole` -> `$0.problems.isEmpty` -> RED.
    func testTheSpeakSelectionSnapshotIsBoundedAndATimeoutIsNotRestorable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/DictationCore/SelectionBorrow.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("readLimit: TimeInterval = PasteboardSnapshot.readLimit"), "the production limit stays the default")
        XCTAssertTrue(text.contains("PasteboardSnapshot.capture(board, timeLimit: readLimit, memory: memory)"))
        XCTAssertTrue(text.contains("snapshot.map { $0.isWhole && !$0.isSensitive }"))
    }

    // MARK: a clipboard that stays slow (#314.1)

    /// A copy that timed out is not read again while nothing has copied since: every later dictation would otherwise
    /// wait the whole limit and make the source app materialise the copy once more.
    /// Mutation: PasteboardSnapshot.capture(_:timeLimit:memory:), delete `if memory.isSlow(at: count) { return unread }`
    /// -> RED (the second take reads again: `reads == 1` fails).
    func testASlowClipboardIsNotReadAgainWhileItsChangeCountIsUnchanged() {
        let board = SlowPasteboard(text: "the user's big copy", delay: 1.5)
        let memory = SlowClipboardMemory()
        XCTAssertEqual(ClipboardBorrow.take(board: board, text: "one", memory: memory, focusMoved: { false },
                                            readLimit: 0.2).delivery, .typed)
        XCTAssertEqual(board.reads, 1, "the first take reads once and gives up")
        let second = ClipboardBorrow.take(board: board, text: "two", memory: memory, focusMoved: { false }, readLimit: 0.2)
        XCTAssertEqual(second.delivery, .typed)
        XCTAssertEqual(board.reads, 1, "the second take must make no data call")
        XCTAssertEqual(board.changeCount, 0, "no clear, no write")
        XCTAssertEqual(board.text, "the user's big copy")
    }

    /// The memory is about ONE copy: a new copy moves the changeCount and is read (and borrowed) again.
    /// Mutation: SlowClipboardMemory.isSlow, `timedOutCount == count` -> `timedOutCount != nil` -> RED.
    func testANewCopyIsReadAgainAfterASlowOne() {
        let board = SlowPasteboard(text: "slow", delay: 0.4)
        let memory = SlowClipboardMemory()
        _ = ClipboardBorrow.take(board: board, text: "one", memory: memory, focusMoved: { false }, readLimit: 0.1)
        Thread.sleep(forTimeInterval: 0.6)   // the abandoned read ends
        let readsBefore = board.reads
        board.inner.userCopies("a fast copy")
        board.inner.items = [[("public.utf8-plain-text", Data("a fast copy".utf8))]]
        let fresh = ClipboardBorrow.take(board: board, text: "two", memory: memory, focusMoved: { false }, readLimit: 5)
        XCTAssertGreaterThan(board.reads, readsBefore, "a copy made after the slow one must be read")
        guard case .lease(let lease) = fresh else { return XCTFail("a readable new copy is borrowed, got \(fresh)") }
        XCTAssertTrue(lease.release())
        XCTAssertEqual(board.text, "a fast copy")
    }

    // MARK: focus moved during the wait (#314.2)

    /// After a wait that ended in `.typed`, keystrokes must not go to whichever app is frontmost now.
    /// Mutation: ClipboardBorrow.take, `typedUnlessFocusMoved` returns `.typed` without asking `focusMoved()` -> RED.
    func testFocusMovingDuringTheWaitDeclinesTheTypedPath() {
        let board = SlowPasteboard(text: "big", delay: 1.0)
        let moved = ClipboardBorrow.take(board: board, text: "t", memory: SlowClipboardMemory(), focusMoved: { true },
                                         readLimit: 0.1)
        XCTAssertEqual(moved.delivery, .clipboardOnly(reason: .focusMoved))
        let stayed = ClipboardBorrow.take(board: board, text: "t", memory: SlowClipboardMemory(), focusMoved: { false },
                                          readLimit: 0.1)
        XCTAssertEqual(stayed.delivery, .typed)
    }

    /// #319.4: focus that moved during a read that FINISHED in time. The lease writes the text and the caller pastes
    /// it; into the new front app that is the wrong place. No lease is made and the board is untouched.
    /// Mutation: ClipboardBorrow.take, delete `if focusMoved() { return .focusMoved }` -> RED (a `.lease` is returned).
    func testFocusMovingDuringAReadThatFinishesInTimeDoesNotPaste() {
        let board = SlowPasteboard(text: "the user's copy", delay: 0.01)
        let moved = ClipboardBorrow.take(board: board, text: "dictated", memory: SlowClipboardMemory(), focusMoved: { true },
                                         readLimit: 5)
        XCTAssertEqual(moved.delivery, .clipboardOnly(reason: .focusMoved))
        XCTAssertEqual(board.changeCount, 0, "no lease, no write over the user's copy")
        XCTAssertEqual(board.text, "the user's copy")
        guard case .lease(let lease) = ClipboardBorrow.take(board: board, text: "dictated", memory: SlowClipboardMemory(),
                                                            focusMoved: { false }, readLimit: 5) else {
            return XCTFail("focus that stayed still pastes as before")
        }
        XCTAssertTrue(lease.release())
    }

    /// The same answer on the remembered fast path (focus is asked after every `.typed`).
    func testFocusIsAlsoCheckedWhenTheSlowClipboardIsRemembered() {
        let board = SlowPasteboard(text: "big", delay: 1.0)
        let memory = SlowClipboardMemory()
        _ = ClipboardBorrow.take(board: board, text: "t", memory: memory, focusMoved: { false }, readLimit: 0.1)
        let again = ClipboardBorrow.take(board: board, text: "t", memory: memory, focusMoved: { true }, readLimit: 0.1)
        XCTAssertEqual(again.delivery, .clipboardOnly(reason: .focusMoved))
    }

    /// The rule PasteOutput applies before AND after the wait: a recording with a target moved when another app is in
    /// front. Mutation: OutputPolicy.focusMoved, `front != target` -> `front == target` -> RED.
    func testFocusMovedRule() {
        XCTAssertFalse(OutputPolicy.focusMoved(target: nil, front: 7), "no target: nothing to be away from")
        XCTAssertFalse(OutputPolicy.focusMoved(target: 7, front: 7))
        XCTAssertTrue(OutputPolicy.focusMoved(target: 7, front: 8))
        XCTAssertTrue(OutputPolicy.focusMoved(target: 7, front: nil), "no frontmost app is not the target")
    }

    // MARK: the notice in the user's language

    private func lease(_ items: [[(String, Data?)]]) -> (FakePasteboard, ClipboardLease) {
        let board = FakePasteboard(text: "")
        board.items = items
        return (board, ClipboardLease(board: board, text: "dictated text"))
    }

    /// The "not put back" notice and every reason are keys: en reads as it always did, ru is Russian.
    /// Mutation: ClipboardLease.release, `text(.clipboardNotPutBack)` -> an English literal -> RED.
    func testTheNotPutBackNoticeIsLocalized() {
        let (_, one) = lease([[("com.apple.pasteboard.promised-file", nil)]])
        XCTAssertFalse(one.release(text: ShippedStrings.localizer("en")))
        XCTAssertEqual(one.notice, "The earlier clipboard was not put back: it held a promised file. The dictated text is on the clipboard.")
        let (_, two) = lease([[("com.apple.pasteboard.promised-file", nil)]])
        XCTAssertFalse(two.release(text: ShippedStrings.localizer("ru")))
        XCTAssertEqual(two.notice, "Прежний буфер обмена не удалось вернуть (в нём: отложенный файл). Надиктованный текст остался в буфере обмена.")
        // Every reason, in both languages.
        for locale in ["en", "ru"] {
            let say = ShippedStrings.localizer(locale)
            XCTAssertFalse(PasteboardProblem.promisedFile.phrase(say).hasPrefix("MISSING"))
            XCTAssertTrue(PasteboardProblem.tooLarge(megabytes: 64).phrase(say).contains("64"), locale)
            XCTAssertFalse(PasteboardProblem.otherDevice.phrase(say).hasPrefix("MISSING"))
            XCTAssertFalse(say(.clipboardReasonJoin).hasPrefix("MISSING"))
        }
        XCTAssertEqual(PasteboardProblem.tooLarge(megabytes: 64).phrase(ShippedStrings.localizer("en")), "more than 64 MB of data")
        XCTAssertEqual(PasteboardProblem.tooLarge(megabytes: 64).phrase(ShippedStrings.localizer("ru")), "больше 64 МБ данных")
    }

    // MARK: legacy promise types

    private func legacyType(_ name: String) -> String {
        UTType(tag: name, tagClass: PasteboardSnapshot.legacyPasteboardTagClass, conformingTo: nil)?.identifier ?? ""
    }

    /// `NSFilesPromisePboardType` and `NSPromiseContentsPboardType` are `dyn.*` identifiers without the word "promise"
    /// in them: they must still count as promised, and their data must never be read.
    /// Mutation: PasteboardSnapshot.isPromisedType, delete the `dyn.` branch -> RED.
    func testLegacyPromiseTypesAreDetectedAndNeverRead() {
        for name in ["NSFilesPromisePboardType", "NSPromiseContentsPboardType"] {
            let type = legacyType(name)
            XCTAssertTrue(type.hasPrefix("dyn."), "\(name) -> \(type): the premise of the test")
            XCTAssertFalse(type.lowercased().contains("promise"))
            let board = FakePasteboard(text: "t")
            board.items[0].append((type: type, data: Data("lazy".utf8)))
            let snapshot = PasteboardSnapshot.capture(board)
            XCTAssertEqual(snapshot.problems, [.promisedFile], name)
            XCTAssertFalse(board.reads.contains(type), "\(name): its data was read")
        }
    }

    /// An ordinary dynamic type (a plain pasteboard type with no declared UTI) is not a promise.
    func testAnOrdinaryDynamicTypeIsStillRead() {
        let type = legacyType("NeXT plain ascii pasteboard type")
        let board = FakePasteboard(text: "t")
        board.items[0].append((type: type, data: Data("plain".utf8)))
        let snapshot = PasteboardSnapshot.capture(board)
        XCTAssertEqual(snapshot.problems, [])
        XCTAssertTrue(board.reads.contains(type))
    }
}
