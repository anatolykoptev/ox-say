import Foundation

/// The pasteboard as dictation output sees it: `NSPasteboard.general` in the app,
/// a fake in tests.
public protocol DictationPasteboard: AnyObject {
    /// Changes on every write to the pasteboard, by any app.
    var changeCount: Int { get }
    /// Every item with every type it carries, to be put back later.
    func snapshot() -> PasteboardSnapshot
    /// Replaces the contents with plain text and returns the resulting changeCount.
    @discardableResult func writeText(_ text: String) -> Int
    /// Replaces the contents with a snapshot.
    func restore(_ snapshot: PasteboardSnapshot)
}

/// The pasteboard contents: one dictionary per item, type identifier to data.
public struct PasteboardSnapshot: Equatable {
    public var items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

/// Borrows the clipboard to deliver dictated text. It remembers what was there,
/// writes the text for a paste, and later puts the original back, but only if
/// nothing has written to the clipboard since. If the user copied something in the
/// meantime, or another app wrote to it, the clipboard is theirs now and restoring
/// would destroy their copy.
public final class ClipboardLease {
    private let board: DictationPasteboard
    private let original: PasteboardSnapshot
    private let ourChange: Int
    private var released = false

    public init(board: DictationPasteboard, text: String) {
        self.board = board
        self.original = board.snapshot()
        self.ourChange = board.writeText(text)
    }

    /// Restores the original contents if the clipboard still holds our text.
    /// Returns whether it did. Only the first call has an effect.
    @discardableResult
    public func release() -> Bool {
        guard !released else { return false }
        released = true
        guard board.changeCount == ourChange else { return false }
        board.restore(original)
        return true
    }
}
