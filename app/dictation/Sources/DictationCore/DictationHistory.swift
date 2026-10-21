import Foundation

/// The last few delivered dictations, newest first, so one whose paste went
/// nowhere is never gone. Memory only: never written to disk, never logged —
/// it holds what the user said, which no log line in this app carries either.
/// Main thread only, like the controller that fills it.
public final class DictationHistory {
    /// Older dictations fall off the end.
    public static let capacity = 10
    /// A menu title is cut to this many characters, ellipsis included.
    public static let titleLimit = 60

    /// The full texts, newest first.
    public private(set) var texts: [String] = []

    public init() {}

    public var isEmpty: Bool { texts.isEmpty }
    /// The newest dictation: what "Paste Last Dictation" sends.
    public var latest: String? { texts.first }

    /// Records a delivered dictation. Empty or whitespace-only text is not a
    /// dictation. The full text is kept; only the menu title is shortened.
    public func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        texts.insert(text, at: 0)
        if texts.count > Self.capacity { texts.removeLast(texts.count - Self.capacity) }
    }

    /// One line for a menu row: whitespace runs (line breaks included)
    /// collapsed to single spaces, cut to `titleLimit` characters with "…".
    public static func title(for text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard line.count > titleLimit else { return line }
        let kept = line.prefix(titleLimit - 1).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    /// The menu titles, newest first.
    public var titles: [String] { texts.map(Self.title(for:)) }
}
