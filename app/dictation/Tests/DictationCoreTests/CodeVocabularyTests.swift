import Foundation
import XCTest
@testable import DictationCore

final class CodeVocabularyTests: XCTestCase {
    /// Mutation: CodeVocabulary.decode, drop the `compactMap` filter (`CodePack(rawValue:)` -> force) is a crash; instead
    /// `?? []` on a missing field -> RED (testAnswerWithoutTheFieldIsNotOff).
    func testDecodeKnownPacksAndIgnoreUnknown() {
        let data = Data(#"{"retention_days":30,"code_vocabulary":["rust","python","cobol"]}"#.utf8)
        XCTAssertEqual(CodeVocabulary.decode(data), [.python, .rust])
        XCTAssertEqual(CodeVocabulary.decode(Data(#"{"code_vocabulary":[]}"#.utf8)), [])
    }

    func testAnswerWithoutTheFieldIsNotOff() {
        XCTAssertNil(CodeVocabulary.decode(Data(#"{"retention_days":30}"#.utf8)))
        XCTAssertNil(CodeVocabulary.decode(Data(#"{"code_vocabulary":"python"}"#.utf8)))
        XCTAssertNil(CodeVocabulary.decode(Data("nope".utf8)))
    }

    /// The toggles round-trip: a flipped switch gives a body the daemon's answer decodes back to the same set, in the
    /// canonical order whatever order the switches were flipped in.
    /// Mutation: CodeVocabulary.body, use `packs.map(\.rawValue)` (set order) -> RED on the order check.
    func testToggleRoundTrip() throws {
        var packs: Set<CodePack> = []
        packs = CodeVocabulary.toggled(packs, .rust, on: true)
        packs = CodeVocabulary.toggled(packs, .python, on: true)
        let body = try CodeVocabulary.body(packs)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"code_vocabulary":["python","rust"]}"#)
        XCTAssertEqual(CodeVocabulary.decode(body), packs)
        packs = CodeVocabulary.toggled(packs, .rust, on: false)
        XCTAssertEqual(CodeVocabulary.decode(try CodeVocabulary.body(packs)), [.python])
        XCTAssertEqual(CodeVocabulary.decode(try CodeVocabulary.body([])), [])
    }

    func testPackIdsAreTheDaemonsIds() {
        XCTAssertEqual(CodePack.allCases.map(\.rawValue), ["python", "go", "rust"])
    }
}
