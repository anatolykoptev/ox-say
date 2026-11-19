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

@MainActor
final class CodePackSyncTests: XCTestCase {
    /// Two quick flips: the saves never overlap, the later choice is sent last, and the page shows the daemon's answer.
    /// Mutation: CodePackSync.choose, drop the `if running { return }` guard -> RED (two puts in flight at once).
    /// Mutation: CodePackSync.choose, drop the `dirty` loop -> RED (the second choice is never sent).
    func testSavesAreSerializedAndTheLatestChoiceWins() async {
        var inFlight = 0, maxInFlight = 0
        var sent: [[String]] = []
        var gate: CheckedContinuation<Void, Never>?
        var applied: CodeVocabularyAnswer?
        let sync = CodePackSync(
            put: { packs, unknown in
                inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
                sent.append(CodePack.allCases.filter(packs.contains).map(\.rawValue) + unknown)
                if sent.count == 1 { await withCheckedContinuation { gate = $0 } }
                inFlight -= 1
            },
            read: { CodeVocabularyAnswer(packs: [.python, .go], unknown: ["zig"]) },
            apply: { applied = $0 })
        sync.learn(CodeVocabularyAnswer(packs: [], unknown: ["zig"]))
        let first = Task { await sync.choose([.python]) }
        while gate == nil { await Task.yield() }
        await sync.choose([.python, .go]) // arrives while the first save is in flight
        gate?.resume()
        await first.value
        XCTAssertEqual(maxInFlight, 1, "saves must not overlap")
        XCTAssertEqual(sent, [["python", "zig"], ["python", "go", "zig"]], "latest last, unknown ids kept")
        XCTAssertEqual(applied, CodeVocabularyAnswer(packs: [.python, .go], unknown: ["zig"]))
        XCTAssertFalse(sync.isBusy)
    }

    func testUnknownIdsSurviveTheBody() throws {
        let answer = CodeVocabulary.decodeAnswer(Data(#"{"code_vocabulary":["rust","zig"]}"#.utf8))
        XCTAssertEqual(answer, CodeVocabularyAnswer(packs: [.rust], unknown: ["zig"]))
        XCTAssertEqual(String(decoding: try CodeVocabulary.body([.rust], keeping: ["zig"]), as: UTF8.self),
                       #"{"code_vocabulary":["rust","zig"]}"#)
    }
}
