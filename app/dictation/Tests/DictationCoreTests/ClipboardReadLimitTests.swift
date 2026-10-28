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
        let taken = ClipboardBorrow.take(board: board, text: "dictated text", readLimit: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the read must not be waited out on the calling thread")
        XCTAssertEqual(taken.delivery, .typed)
        XCTAssertEqual(board.changeCount, 0, "no clear, no write")
        XCTAssertEqual(board.text, "the user's big copy")
        XCTAssertEqual(board.inner.items.map { $0.map(\.type) }, before)
    }

    /// A read that finishes in time still pastes and restores, exactly as before.
    func testAReadInsideTheLimitStillPastesAndRestores() {
        let board = SlowPasteboard(text: "the user's copy", delay: 0.01)
        guard case .lease(let lease) = ClipboardBorrow.take(board: board, text: "dictated text", readLimit: 5) else {
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
        XCTAssertTrue(text.contains("PasteboardSnapshot.capture(board, timeLimit: PasteboardSnapshot.readLimit)"))
        XCTAssertTrue(text.contains("snapshot.map { $0.isWhole && !$0.isSensitive }"))
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
