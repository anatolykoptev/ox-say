import Foundation
import UniformTypeIdentifiers

/// The pasteboard as dictation output sees it: `NSPasteboard.general` in the app,
/// a fake in tests.
public protocol DictationPasteboard: AnyObject {
    /// Changes on every write to the pasteboard, by any app.
    var changeCount: Int { get }
    /// The type identifiers each item declares, in the item's own order.
    var declaredItems: [[String]] { get }
    /// The data behind a declared type of an item, or nil when the source
    /// cannot or will not give it. Only types PasteboardSnapshot asks for are
    /// read; promised types are never read through here.
    func data(item: Int, forType type: String) -> Data?
    /// Replaces the contents with plain text and returns the resulting changeCount.
    @discardableResult func writeText(_ text: String) -> Int
    /// Replaces the contents with a snapshot.
    func restore(_ snapshot: PasteboardSnapshot)
}

extension DictationPasteboard {
    /// Any item declares a Universal Clipboard copy made on another device.
    /// Declared types only — reading the data behind any of them makes macOS
    /// fetch the contents from that device, which shows a panel and stalls.
    public var holdsRemoteCopy: Bool {
        PasteboardMarker.declaresRemote(declaredItems)
    }
}

/// One type an item carried, with its data, kept in the item's declared order:
/// the order is the priority a reader picks formats by, so a restore must keep it.
public struct PasteboardEntry: Equatable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Why a snapshot is not exactly what the user had.
public enum PasteboardProblem: Equatable {
    /// A file promise: reading it runs the source app's provider.
    case promisedFile
    /// More data than `PasteboardSnapshot.maxBytes`.
    case tooLarge(megabytes: Int)
    /// A Universal Clipboard copy: its data lives on another device.
    case otherDevice

    /// The reason in the user's language, as a phrase for `clipboard.not_put_back`.
    public func phrase(_ text: (L10nKey) -> String) -> String {
        switch self {
        case .promisedFile: return text(.clipboardReasonPromised)
        case .tooLarge(let megabytes): return String(format: text(.clipboardReasonTooLarge), String(megabytes))
        case .otherDevice: return text(.clipboardReasonOtherDevice)
        }
    }
}

/// The pasteboard contents: the types of every item in each item's declared
/// order, with their data — plus the reasons the snapshot is not a whole copy.
public struct PasteboardSnapshot: Equatable {
    public var items: [[PasteboardEntry]]
    /// Why the snapshot is not exactly what the user had. Non-empty means it
    /// must not be put back: it would be a different clipboard, silently.
    public private(set) var problems: [PasteboardProblem]
    /// The read did not finish in time (`capture(_:timeLimit:)`): there is no snapshot of the user's copy at all.
    /// Whoever sees this must leave the clipboard alone: nothing could put it back.
    public private(set) var timedOut = false
    /// A whole copy of what the user had: nothing is missing, so it may be put back.
    public var isWhole: Bool { problems.isEmpty && !timedOut }
    /// Holding more than this for a restore costs more than the restore saves.
    public static let maxBytes = 64 * 1024 * 1024

    public init(items: [[PasteboardEntry]], problems: [PasteboardProblem] = []) {
        self.items = items
        self.problems = problems
    }

    /// How long the main thread waits for the clipboard's data before it gives the user's copy up (see `capture`).
    public static let readLimit: TimeInterval = 2

    /// `capture(board)` on a background queue, waited for at most `timeLimit` seconds. A type provided lazily (a big
    /// image copied in Preview) is materialised by the READ, which can take seconds and, on the main thread, freezes
    /// the app and the key the user holds; and the 64 MB cap only applies after that read. On a timeout the result is
    /// a snapshot with `timedOut` set and nothing in it: the caller must not write over the clipboard (nothing could
    /// bring the user's copy back). The background read is told to stop before its next `data` call and its result
    /// is dropped. nil `timeLimit` reads in place, as `capture`.
    public static func capture(_ board: DictationPasteboard, timeLimit: TimeInterval?) -> PasteboardSnapshot {
        guard let timeLimit else { return capture(board) }
        let box = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(capture(board, shouldContinue: { !box.cancelled }))
            done.signal()
        }
        if done.wait(timeout: .now() + timeLimit) == .success, let snapshot = box.value { return snapshot }
        box.cancel()
        return unread
    }

    /// The snapshot of a clipboard that was not read (it timed out, now or on an earlier look): nothing in it, `timedOut` set.
    static var unread: PasteboardSnapshot {
        var late = PasteboardSnapshot(items: [])
        late.timedOut = true
        return late
    }

    /// `capture(_:timeLimit:)` that does not read a copy `memory` already knows to be slow: while the pasteboard's
    /// `changeCount` is still that of the slow copy the answer is `unread` at once, with no `data` call. A read that
    /// times out is remembered, one that finishes ends the memory. The one place both clipboard readers (the paste
    /// and the speak-selection copy) take their bounded snapshot, so neither can forget the memory.
    public static func capture(_ board: DictationPasteboard, timeLimit: TimeInterval,
                               memory: SlowClipboardMemory) -> PasteboardSnapshot {
        let count = board.changeCount
        if memory.isSlow(at: count) { return unread }
        let snapshot = capture(board, timeLimit: timeLimit)
        if snapshot.timedOut { memory.remember(count) } else { memory.forget() }
        return snapshot
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: PasteboardSnapshot?
        private var isCancelled = false
        var value: PasteboardSnapshot? { lock.withLock { snapshot } }
        var cancelled: Bool { lock.withLock { isCancelled } }
        func set(_ new: PasteboardSnapshot) { lock.withLock { snapshot = new } }
        func cancel() { lock.withLock { isCancelled = true } }
    }

    /// Copies every type of every item on `board`, in declared order. A
    /// Universal Clipboard copy (a declared remote marker) is not read at all.
    /// Promised types are never read: reading one runs the source app's
    /// provider synchronously, which can stall for seconds on a big promise.
    /// A promise and a clipboard over `maxBytes` go into `problems`: the
    /// snapshot then is not the user's copy, and putting it back would hand
    /// them a different clipboard without a word.
    /// A type that gives no data is left out without a problem: no app can
    /// paste it either, so the restore loses nothing a reader could get, and
    /// refusing the restore over it would throw away everything else.
    public static func capture(_ board: DictationPasteboard) -> PasteboardSnapshot {
        capture(board, shouldContinue: { true })
    }

    /// `shouldContinue` is asked before every `data` read: false stops the capture there (the timed-out background read).
    static func capture(_ board: DictationPasteboard, shouldContinue: () -> Bool) -> PasteboardSnapshot {
        var snapshot = PasteboardSnapshot(items: [])
        var bytes = 0
        // Asked once: the same list decides "remote" and is enumerated below, so
        // a remote copy landing in between cannot get its marker type read.
        let declared = board.declaredItems
        if PasteboardMarker.declaresRemote(declared) {
            snapshot.isRemote = true
            snapshot.report(.otherDevice)
            return snapshot
        }
        capture: for (index, types) in declared.enumerated() {
            var entries: [PasteboardEntry] = []
            for type in types {
                if isPromisedType(type) {
                    snapshot.report(.promisedFile)
                    continue
                }
                guard shouldContinue() else { break capture }
                guard let data = board.data(item: index, forType: type) else { continue }
                bytes += data.count
                if bytes > maxBytes {
                    snapshot.report(.tooLarge(megabytes: maxBytes / (1024 * 1024)))
                    break capture
                }
                entries.append(PasteboardEntry(type: type, data: data))
            }
            snapshot.items.append(entries)
        }
        return snapshot
    }

    /// The clipboard held a Universal Clipboard copy from another device. Its
    /// data was not read: reading any type makes macOS fetch the contents from
    /// that device, which shows a panel and stalls the paste.
    public private(set) var isRemote = false

    fileprivate mutating func report(_ problem: PasteboardProblem) {
        if !problems.contains(problem) { problems.append(problem) }
    }

    /// A promised type carries no data until the source app is asked for it;
    /// asking runs the source's provider on this thread. Apple's promise UTIs
    /// all carry "promise" (com.apple.pasteboard.promised-file,
    /// com.apple.pasteboard.promised-file-url, com.apple.NSFilePromise).
    ///
    /// The legacy `NSFilesPromisePboardType` and `NSPromiseContentsPboardType` surface as `dyn.*` identifiers whose
    /// text does not carry the word; their pasteboard-type name is recovered from the identifier.
    private static func isPromisedType(_ type: String) -> Bool {
        if type.lowercased().contains("promise") { return true }
        guard type.hasPrefix("dyn."), let legacy = UTType(type)?.tags[legacyPasteboardTagClass] else { return false }
        return legacy.contains { $0.lowercased().contains("promise") }
    }

    /// The tag class of the old NSPasteboard type names (`kUTTagClassNSPboardType`, deprecated as a constant).
    static let legacyPasteboardTagClass = UTTagClass(rawValue: "com.apple.nspboard-type")

    /// Marked by its writer as a secret (nspasteboard.org convention, used by
    /// password managers). Such contents are not put back.
    public var isSensitive: Bool {
        items.contains { item in item.contains { PasteboardMarker.sensitive.contains($0.type) } }
    }
}

/// Type identifiers from nspasteboard.org that clipboard managers and password
/// managers agree on.
public enum PasteboardMarker {
    /// A secret, e.g. a password copied from a password manager.
    public static let concealed = "org.nspasteboard.ConcealedType"
    /// Short-lived: clipboard managers do not keep it in their history.
    public static let transient = "org.nspasteboard.TransientType"
    /// Written by software, not copied by the user.
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"

    /// Contents carrying any of these are a secret: not put back after a paste.
    public static let sensitive = [concealed]
    /// Declared by a Universal Clipboard copy made on another device.
    public static let remoteClipboard = "com.apple.is-remote-clipboard"
    /// Declaring any of these means the contents live on another device.
    public static let remote = [remoteClipboard]

    /// Any item declares a remote marker.
    public static func declaresRemote(_ declaredItems: [[String]]) -> Bool {
        declaredItems.contains { $0.contains(where: remote.contains) }
    }
    /// Added to the user's contents when they are put back: it is not a new copy,
    /// so clipboard managers skip it. Must not overlap `sensitive`, or the next
    /// dictation would take the restored contents for a secret and drop them.
    public static let restored = [autoGenerated]
}

/// Borrows the clipboard to deliver dictated text. It remembers what was there,
/// writes the text for a paste, and later puts the original back, but only if
/// nothing has written to the clipboard since. If the user copied something in the
/// meantime, or another app wrote to it, the clipboard is theirs now and restoring
/// would destroy their copy.
///
/// A secret (a password manager's copy) is never put back: a password manager
/// clears the clipboard later only if it still holds the manager's own write, so
/// restoring it would leave the password on the clipboard for good.
public final class ClipboardLease {
    private let board: DictationPasteboard
    private let original: PasteboardSnapshot
    private let ourChange: Int
    /// Why `release` left our text instead of putting the original back: the
    /// snapshot was not a whole copy of what the user had. nil when the
    /// clipboard was left because someone else wrote to it — that copy is the
    /// user's own.
    public private(set) var notice: String?

    /// Only `ClipboardBorrow.take` makes a lease in the app, so one is never made over a snapshot that timed out.
    init(board: DictationPasteboard, original: PasteboardSnapshot, text: String) {
        self.board = board
        self.original = original
        self.ourChange = board.writeText(text)
    }

    /// Reads the clipboard in place and borrows it: for tests, where reading cannot stall.
    convenience init(board: DictationPasteboard, text: String) {
        self.init(board: board, original: PasteboardSnapshot.capture(board), text: text)
    }

    /// Restores the original contents if the clipboard still holds our text.
    /// Returns whether it did. Only the first call can: restoring is a write.
    /// `text` words the notice in the user's language.
    @discardableResult
    public func release(text: (L10nKey) -> String = { $0.text }) -> Bool {
        guard board.changeCount == ourChange else { return false }
        guard !original.isSensitive else { return false }
        guard original.problems.isEmpty else {
            let reasons = original.problems.map { $0.phrase(text) }.joined(separator: text(.clipboardReasonJoin))
            notice = String(format: text(.clipboardNotPutBack), reasons)
            return false
        }
        board.restore(original)
        return true
    }
}

/// How a paste gets the clipboard. The snapshot is taken BEFORE anything is written: a clipboard that could not be
/// read in time (`readLimit`) is never touched, because writing the dictated text would clear the user's copy with
/// nothing to put back. The text is typed instead, as over a Universal Clipboard copy.
public enum ClipboardBorrow {
    case lease(ClipboardLease)
    /// The clipboard could not be read in time and was left exactly as it was.
    case typed
    /// Like `.typed`, but the frontmost app is no longer the one the dictation was for: keystrokes would go to the
    /// wrong app. The caller leaves the text on the clipboard, as for focus that moved before the wait.
    case focusMoved

    /// - Parameters:
    ///   - memory: the caller's `SlowClipboardMemory`; a copy that timed out is not read again until the clipboard changes.
    ///   - focusMoved: asked after the read, whatever its outcome: the frontmost app may have changed during the
    ///     up-to-`readLimit` read, and both the keystrokes of `.typed` and the ⌘V that follows a `.lease` would go to
    ///     it. A lease is only made when focus is still where it was, so nothing is written for a paste that
    ///     would land elsewhere. No default: a caller that forgets it pastes into the wrong app.
    public static func take(board: DictationPasteboard, text: String, memory: SlowClipboardMemory,
                            focusMoved: () -> Bool,
                            readLimit: TimeInterval = PasteboardSnapshot.readLimit) -> ClipboardBorrow {
        let original = PasteboardSnapshot.capture(board, timeLimit: readLimit, memory: memory)
        if original.timedOut { return typedUnlessFocusMoved(focusMoved) }
        // The read may have taken up to `readLimit`: focus can have moved while it finished in time, and a lease
        // writes the text and the caller pastes it — into whichever app is in front now. Decided BEFORE the write.
        if focusMoved() { return .focusMoved }
        return .lease(ClipboardLease(board: board, original: original, text: text))
    }

    private static func typedUnlessFocusMoved(_ focusMoved: () -> Bool) -> ClipboardBorrow {
        focusMoved() ? .focusMoved : .typed
    }

    /// How the text reaches the user.
    public var delivery: Delivery {
        switch self {
        case .lease: return .paste
        case .typed: return .typed
        case .focusMoved: return .clipboardOnly(reason: .focusMoved)
        }
    }
}

/// The clipboard copy whose read timed out, remembered by the caller (one per output, not a global). While the
/// pasteboard's `changeCount` is still that of the slow copy, `ClipboardBorrow.take` types at once: reading it again
/// would cost the whole limit on every dictation and make the source app materialise the copy each time. Any write
/// to the clipboard moves the count and ends the memory.
public final class SlowClipboardMemory {
    private var timedOutCount: Int?

    public init() {}

    func isSlow(at changeCount: Int) -> Bool { timedOutCount == changeCount }
    func remember(_ changeCount: Int) { timedOutCount = changeCount }
    func forget() { timedOutCount = nil }
}
