import Foundation

/// One place the find matched: a turn and the Character range inside its text.
public struct TranscriptMatch: Equatable {
    public var turnID: Int
    public var range: Range<Int>
}

/// Find inside the open transcript (⌘F): every match of the query in the turns, and the one the user is on. The
/// comparison is the daemon's fold, so a hit the search found is a match here too. Pure; the view only draws it.
public struct TranscriptFindState: Equatable {
    public private(set) var query: String
    public private(set) var matches: [TranscriptMatch]
    /// An index into `matches`; nil when nothing matched.
    public private(set) var current: Int?

    public init(query: String = "", turns: [TranscriptTurn] = []) {
        self.query = query
        self.matches = []
        self.current = nil
        setQuery(query, turns: turns)
    }

    /// A new query starts at its first match.
    public mutating func setQuery(_ new: String, turns: [TranscriptTurn]) {
        query = new
        matches = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : turns.flatMap { turn in
            TextFold.ranges(of: new, in: turn.text).map { TranscriptMatch(turnID: turn.id, range: $0) }
        }
        current = matches.isEmpty ? nil : 0
    }

    public mutating func next() {
        guard let i = current else { return }
        current = (i + 1) % matches.count
    }

    public mutating func previous() {
        guard let i = current else { return }
        current = (i - 1 + matches.count) % matches.count
    }

    public var currentTurnID: Int? { current.map { matches[$0].turnID } }

    /// "n of m", 1-based; nil when nothing matched.
    public var position: (index: Int, total: Int)? { current.map { ($0 + 1, matches.count) } }

    /// The ranges of one turn, and which of them (an index into the returned array) is the current match.
    public func marks(in turnID: Int) -> (ranges: [Range<Int>], current: Int?) {
        var ranges: [Range<Int>] = []
        var cur: Int?
        for (i, m) in matches.enumerated() where m.turnID == turnID {
            if i == current { cur = ranges.count }
            ranges.append(m.range)
        }
        return (ranges, cur)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.query == b.query && a.matches == b.matches && a.current == b.current
    }
}
