import Foundation
import XCTest
@testable import DictationCore

final class TranscriptFindTests: XCTestCase {
    private let turns = [
        TranscriptTurn(id: 0, speaker: "You", time: "0:05", text: "Всем привет, начнём встречу"),
        TranscriptTurn(id: 1, speaker: "Anna", time: "0:12", text: "Ёжик пришёл, ежик ушёл"),
        TranscriptTurn(id: 2, speaker: "You", time: "1:00", text: "Нет совпадений здесь"),
        TranscriptTurn(id: 3, speaker: "Anna", time: "1:30", text: "Ещё один ЕЖИК"),
    ]

    /// The find sees what the daemon's search saw: case, ё/е.
    /// Mutation: TranscriptFindState.matches, compare `turn.text` raw instead of folded -> RED.
    func testFindIgnoresCaseAndYo() {
        let s = TranscriptFindState(query: "ежик", turns: turns)
        XCTAssertEqual(s.matches.map(\.turnID), [1, 1, 3])
        XCTAssertEqual(s.matches[1].range, 13..<17)
        XCTAssertEqual(s.position?.index, 1)
        XCTAssertEqual(s.position?.total, 3)
    }

    /// Next and previous wrap around; the counter is "n of m"; no match is no position.
    /// Mutation: TranscriptFindState.next, `(i + 1) % matches.count` -> `min(i + 1, matches.count - 1)` -> RED.
    func testNextAndPreviousWrap() {
        var s = TranscriptFindState(query: "ежик", turns: turns)
        s.next(); XCTAssertEqual(s.currentTurnID, 1)
        s.next(); XCTAssertEqual(s.currentTurnID, 3)
        s.next(); XCTAssertEqual(s.currentTurnID, 1, "wraps to the first")
        XCTAssertEqual(s.position?.index, 1)
        s.previous(); XCTAssertEqual(s.currentTurnID, 3, "and back to the last")
        XCTAssertEqual(s.position?.index, 3)
        var none = TranscriptFindState(query: "zzz", turns: turns)
        none.next(); none.previous()
        XCTAssertNil(none.position)
        XCTAssertNil(none.currentTurnID)
    }

    /// An empty or blank query finds nothing; a new query starts at the first match.
    func testBlankQueryAndRestart() {
        XCTAssertTrue(TranscriptFindState(query: "", turns: turns).matches.isEmpty)
        XCTAssertTrue(TranscriptFindState(query: "   ", turns: turns).matches.isEmpty)
        var s = TranscriptFindState(query: "ежик", turns: turns)
        s.next()
        s.setQuery("встреч", turns: turns)
        XCTAssertEqual(s.position?.index, 1)
        XCTAssertEqual(s.currentTurnID, 0)
    }

    /// The text of a turn with its matches marked, the current one apart; no link is ever made.
    func testHighlightMarksMatchesAndTheCurrentOne() {
        let ms = TextFold.ranges(of: "ежик", in: "Ёжик пришёл, ежик ушёл")
        let a = TextHighlight.attributed("Ёжик пришёл, ежик ушёл", ranges: ms, current: 1)
        let marks = a.runs.compactMap { run -> (String, TextHighlight.Kind)? in
            guard let k = run.oxsayHighlight else { return nil }
            return (String(a[run.range].characters), k)
        }
        XCTAssertEqual(marks.map(\.0), ["Ёжик", "ежик"])
        XCTAssertEqual(marks.map(\.1), [.match, .current])
        XCTAssertTrue(a.runs.allSatisfy { $0.link == nil })
    }
}
