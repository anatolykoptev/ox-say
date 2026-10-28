import CoreServices
import Foundation
import XCTest
@testable import DictationCore

/// A pasteboard whose data takes `delay` seconds to materialise, like a big image copied in Preview.
final class SlowPasteboard: DictationPasteboard {
    private let inner: FakePasteboard
    private let delay: TimeInterval
    init(text: String, delay: TimeInterval) { inner = FakePasteboard(text: text); self.delay = delay }
    var changeCount: Int { inner.changeCount }
    var declaredItems: [[String]] { inner.declaredItems }
    func data(item: Int, forType type: String) -> Data? {
        Thread.sleep(forTimeInterval: delay)
        return inner.data(item: item, forType: type)
    }
    @discardableResult func writeText(_ text: String) -> Int { inner.writeText(text) }
    func restore(_ snapshot: PasteboardSnapshot) { inner.restore(snapshot) }
    var text: String { inner.text }
}

final class ClipboardReadLimitTests: XCTestCase {
    /// A lazy type that takes longer than the limit does not hold the caller: the snapshot comes back at the limit,
    /// is not a whole copy, and the lease leaves the dictated text and says why instead of restoring.
    /// Mutation: ClipboardLease.init, `PasteboardSnapshot.capture(board, timeLimit: readLimit)` -> `timeLimit: nil` -> RED
    /// (the init waits out the slow read and then restores).
    func testASlowClipboardReadDoesNotHoldTheCallerAndIsNotRestored() {
        let board = SlowPasteboard(text: "the user's big copy", delay: 1.5)
        let started = Date()
        let lease = ClipboardLease(board: board, text: "dictated text", readLimit: 0.1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the read must not be waited out on the calling thread")
        XCTAssertEqual(board.text, "dictated text", "the text is on the clipboard for the paste")
        XCTAssertFalse(lease.release(), "a snapshot that was not taken is never put back")
        XCTAssertTrue(lease.notice?.contains("took too long to read") ?? false, lease.notice ?? "nil")
        XCTAssertEqual(board.text, "dictated text")
    }

    /// A read that finishes in time is a whole snapshot, exactly as before.
    func testAReadInsideTheLimitIsRestoredAsBefore() {
        let board = SlowPasteboard(text: "the user's copy", delay: 0.01)
        let lease = ClipboardLease(board: board, text: "dictated text", readLimit: 5)
        XCTAssertTrue(lease.release())
        XCTAssertEqual(board.text, "the user's copy")
        XCTAssertNil(lease.notice)
    }

    /// The speak-selection snapshot is bounded the same way: a slow clipboard declines the copy instead of freezing the
    /// key, and ⌘C is never sent over it.
    func testTheTimeoutSnapshotCarriesTheReason() {
        let board = SlowPasteboard(text: "x", delay: 1.0)
        let snapshot = PasteboardSnapshot.capture(board, timeLimit: 0.05)
        XCTAssertEqual(snapshot.problems, ["a copy that took too long to read"])
        XCTAssertTrue(snapshot.items.isEmpty)
        let unbounded = PasteboardSnapshot.capture(SlowPasteboard(text: "x", delay: 0.01), timeLimit: nil)
        XCTAssertTrue(unbounded.problems.isEmpty)
    }

    /// The speak-selection path takes its snapshot through the limit. Mutation: SelectionBorrow.run, `timeLimit:
    /// PasteboardSnapshot.readLimit` -> drop the limit (`PasteboardSnapshot.capture(board)`) -> RED.
    func testTheSpeakSelectionSnapshotIsBounded() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/DictationCore/SelectionBorrow.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("PasteboardSnapshot.capture(board, timeLimit: PasteboardSnapshot.readLimit)"))
    }

    // MARK: legacy promise types

    private func legacyType(_ name: String) -> String {
        (UTTypeCreatePreferredIdentifierForTag(kUTTagClassNSPboardType, name as CFString, nil)?.takeRetainedValue() as String?) ?? ""
    }

    /// `NSFilesPromisePboardType` and `NSPromiseContentsPboardType` are `dyn.*` identifiers without the word "promise"
    /// in them: they must still count as promised, and their data must never be read (the source app's provider runs on
    /// the reading thread).
    /// Mutation: PasteboardSnapshot.isPromisedType, delete the `dyn.` branch -> RED.
    func testLegacyPromiseTypesAreDetectedAndNeverRead() {
        for name in ["NSFilesPromisePboardType", "NSPromiseContentsPboardType"] {
            let type = legacyType(name)
            XCTAssertTrue(type.hasPrefix("dyn."), "\(name) -> \(type): the premise of the test")
            XCTAssertFalse(type.lowercased().contains("promise"))
            let board = FakePasteboard(text: "t")
            board.items[0].append((type: type, data: Data("lazy".utf8)))
            let snapshot = PasteboardSnapshot.capture(board)
            XCTAssertEqual(snapshot.problems, ["a promised file"], name)
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
