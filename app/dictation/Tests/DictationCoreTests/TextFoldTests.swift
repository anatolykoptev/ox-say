import Foundation
import XCTest
@testable import DictationCore

/// The fold is the daemon's (`internal/meeting/search.go` foldRune): the transcript find and the snippet emphasis must
/// match exactly where the daemon matched, or a hit would open on a line the find then cannot see. The cases are the
/// daemon's own (`internal/daemon/meetings_search_test.go` TestSearchIgnoresCaseAndYoInRussian).
final class TextFoldTests: XCTestCase {
    private func found(_ needle: String, in text: String) -> Bool { !TextFold.ranges(of: needle, in: text).isEmpty }

    /// ё folds to е in both directions, whatever the case; й stays its own letter.
    /// Mutation: TextFold.swift accents table, delete the `"е": "ё"` group -> RED.
    func testYoFoldsToYeAndShortIDoesNotFoldToI() {
        XCTAssertTrue(found("елочные", in: "Обсудили ёлочные игрушки."))
        XCTAssertTrue(found("ЁЛОЧНЫЕ", in: "Обсудили ёлочные игрушки."))
        XCTAssertTrue(found("пришел", in: "Ёжик пришёл, мой друг"))
        XCTAssertTrue(found("ЕЖИК", in: "Ёжик пришёл, мой друг"))
        XCTAssertTrue(found("пришёл", in: "ежик пришел"))
        XCTAssertFalse(found("мои друг", in: "Ёжик пришёл, мой друг"), "й is not и")
        XCTAssertTrue(found("МОЙ друг", in: "Ёжик пришёл, мой друг"))
        XCTAssertEqual(TextFold.folded("Й"), "й")
    }

    /// Latin letters with accents fold to the plain letter; the match is a substring, not a word.
    func testLatinAccentsAndCase() {
        for q in ["cafe", "CAFÉ", "societe"] { XCTAssertTrue(found(q, in: "Café société"), q) }
        XCTAssertFalse(found("ÉTÉS", in: "Café société"))
        XCTAssertEqual(TextFold.folded("Straße ŉ İ ς ſ"), "straße n i σ s")
    }

    /// Ranges are Character offsets, left to right, not overlapping; an empty needle matches nothing.
    func testRangesAreCharacterOffsets() {
        XCTAssertEqual(TextFold.ranges(of: "ab", in: "xABabAb"), [1..<3, 3..<5, 5..<7])
        XCTAssertEqual(TextFold.ranges(of: "aa", in: "aaa"), [0..<2])
        XCTAssertEqual(TextFold.ranges(of: "", in: "abc"), [])
        XCTAssertEqual(TextFold.ranges(of: "ёж", in: "Мой Ёж"), [4..<6])
        // An emoji is one Character but several scalars: the offsets still count Characters.
        XCTAssertEqual(TextFold.ranges(of: "ok", in: "👩‍👩‍👧 ok"), [2..<4])
    }
}
