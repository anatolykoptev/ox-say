import CoreServices
import Foundation

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

/// The pasteboard contents: the types of every item in each item's declared
/// order, with their data — plus the reasons the snapshot is not a whole copy.
public struct PasteboardSnapshot: Equatable {
    public var items: [[PasteboardEntry]]
    /// Why the snapshot is not exactly what the user had. Non-empty means it
    /// must not be put back: it would be a different clipboard, silently.
    public private(set) var problems: [String]
    /// Holding more than this for a restore costs more than the restore saves.
    public static let maxBytes = 64 * 1024 * 1024

    public init(items: [[PasteboardEntry]], problems: [String] = []) {
        self.items = items
        self.problems = problems
    }

    /// How long the main thread waits for the clipboard's data before it gives the user's copy up (see `capture`).
    public static let readLimit: TimeInterval = 2

    /// `capture(board)` on a background queue, waited for at most `timeLimit` seconds. A type provided lazily (a big
    /// image copied in Preview) is materialised by the READ, which can take seconds and, on the main thread, freezes
    /// the app and the key the user holds; and the 64 MB cap only applies after that read. On a timeout the result is
    /// a snapshot that is not the user's copy ("took too long to read"), so it is not put back and the lease says so;
    /// the read goes on in the background and its result is dropped. nil `timeLimit` reads in place, as `capture`.
    public static func capture(_ board: DictationPasteboard, timeLimit: TimeInterval?) -> PasteboardSnapshot {
        guard let timeLimit else { return capture(board) }
        let box = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(capture(board))
            done.signal()
        }
        if done.wait(timeout: .now() + timeLimit) == .success, let snapshot = box.value { return snapshot }
        var late = PasteboardSnapshot(items: [])
        late.report("a copy that took too long to read")
        return late
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: PasteboardSnapshot?
        var value: PasteboardSnapshot? { lock.withLock { snapshot } }
        func set(_ new: PasteboardSnapshot) { lock.withLock { snapshot = new } }
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
        var snapshot = PasteboardSnapshot(items: [])
        var bytes = 0
        // Asked once: the same list decides "remote" and is enumerated below, so
        // a remote copy landing in between cannot get its marker type read.
        let declared = board.declaredItems
        if PasteboardMarker.declaresRemote(declared) {
            snapshot.isRemote = true
            snapshot.report("a clipboard copied on another device")
            return snapshot
        }
        capture: for (index, types) in declared.enumerated() {
            var entries: [PasteboardEntry] = []
            for type in types {
                if isPromisedType(type) {
                    snapshot.report("a promised file")
                    continue
                }
                guard let data = board.data(item: index, forType: type) else { continue }
                bytes += data.count
                if bytes > maxBytes {
                    snapshot.report("more than \(maxBytes / (1024 * 1024)) MB of data")
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

    /// The entries a restore may write: never the remote marker. Written back,
    /// it would make our own restored copy look remote, and every later
    /// dictation would trigger the fetch again.
    public var restorableItems: [[PasteboardEntry]] {
        items.map { $0.filter { !PasteboardMarker.remote.contains($0.type) } }
    }

    fileprivate mutating func report(_ problem: String) {
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
        guard type.hasPrefix("dyn."),
              let legacy = UTTypeCopyPreferredTagWithClass(type as CFString, kUTTagClassNSPboardType)?.takeRetainedValue() as String?
        else { return false }
        return legacy.lowercased().contains("promise")
    }

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

    /// `readLimit`: how long the snapshot of the user's clipboard may take (`PasteboardSnapshot.capture(_:timeLimit:)`).
    public init(board: DictationPasteboard, text: String, readLimit: TimeInterval = PasteboardSnapshot.readLimit) {
        self.board = board
        self.original = PasteboardSnapshot.capture(board, timeLimit: readLimit)
        self.ourChange = board.writeText(text)
    }

    /// Restores the original contents if the clipboard still holds our text.
    /// Returns whether it did. Only the first call can: restoring is a write.
    @discardableResult
    public func release() -> Bool {
        guard board.changeCount == ourChange else { return false }
        guard !original.isSensitive else { return false }
        guard original.problems.isEmpty else {
            notice = "The earlier clipboard was not put back: it held \(original.problems.joined(separator: " and ")). The dictated text is on the clipboard."
            return false
        }
        board.restore(original)
        return true
    }
}
