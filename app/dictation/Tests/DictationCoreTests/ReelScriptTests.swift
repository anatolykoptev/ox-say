import XCTest
@testable import DictationCore

/// The Reel editor's pure rules: how the script becomes phrases (the daemon's
/// paragraphs), how its chunks map back onto them, and when "Озвучить" is live.
final class ReelScriptTests: XCTestCase {
    // MARK: R1 — phrases are blank-line-separated paragraphs

    /// A multi-line paragraph stays one phrase; CRLF endings are the same
    /// line breaks as LF. Mutation: split on single newlines -> RED here.
    func testPhrasesAreBlankLineBlocks() {
        XCTAssertEqual(ReelScript.phrases(of: "Один.\r\nДва.\r\n\r\nТри."), ["Один.\nДва.", "Три."])
    }

    func testSeveralBlankLinesAndWhitespaceOnlyLinesAreOneBreak() {
        XCTAssertEqual(ReelScript.phrases(of: "Первый.\n\n\n   \n\t\nВторой."), ["Первый.", "Второй."])
    }

    func testASingleParagraphIsOnePhrase() {
        XCTAssertEqual(ReelScript.phrases(of: "Только один абзац."), ["Только один абзац."])
    }

    func testATrailingBlankLineEndsTheLastPhrase() {
        XCTAssertEqual(ReelScript.phrases(of: "Текст.\n\n"), ["Текст."])
    }

    /// A directive is text the daemon reads, not a split point; it stays
    /// inside its phrase, literal.
    func testAPauseDirectiveStaysInsideItsPhrase() {
        XCTAssertEqual(ReelScript.phrases(of: "Стоп. [pause 1s]\n\nДальше."), ["Стоп. [pause 1s]", "Дальше."])
    }

    func testAPhraseIsTrimmedAndAnEmptyScriptHasNone() {
        XCTAssertEqual(ReelScript.phrases(of: "  Текст.  \n\n   Ещё.   "), ["Текст.", "Ещё."])
        XCTAssertEqual(ReelScript.phrases(of: " \n\n \t \n"), [])
    }

    /// The daemon counts only paragraphs that produce chunks: one of nothing
    /// but [pause …] emits none and does not take a paragraph number.
    func testAPauseOnlyPhraseEmitsNothing() {
        XCTAssertFalse(ReelScript.emits("[pause 1s]"))
        XCTAssertFalse(ReelScript.emits(" [pause 1s]\n[pause 300ms] "))
        XCTAssertTrue(ReelScript.emits("Стоп. [pause 1s]"))
        XCTAssertTrue(ReelScript.emits("[style: тепло]\nТекст."))
    }

    // MARK: R3 — chunks map onto phrases through the paragraph index

    private func chunk(_ index: Int, _ status: String) -> ProduceChunk {
        ProduceChunk(index: index, status: ProduceChunkState(status))
    }

    /// Several chunks share one paragraph: the phrase is done only when every
    /// one of them is, and renders while it holds the daemon's current chunk.
    /// Mutation: map a phrase to its first chunk only -> RED.
    func testPhraseStatesFollowEveryChunkOfTheParagraph() {
        let chunks = [chunk(0, "ok"), chunk(1, "ok"), chunk(2, "ok"), chunk(3, "pending"), chunk(4, "pending")]
        let paragraphs = [0: 0, 1: 0, 2: 1, 3: 1, 4: 2]
        let states = ReelScript.phraseStates(emitting: [true, true, true], chunks: chunks, paragraphOf: paragraphs)
        XCTAssertEqual(states, [.done, .rendering, .pending])
    }

    /// A chunk the automatic checks could not pass ("review") fails its phrase.
    func testAFailedChunkFailsItsPhrase() {
        let chunks = [chunk(0, "ok"), chunk(1, "review")]
        let states = ReelScript.phraseStates(emitting: [true], chunks: chunks, paragraphOf: [0: 0, 1: 0])
        XCTAssertEqual(states, [.failed])
    }

    /// The daemon renders chunks in order: pending chunks behind the one in
    /// flight are still pending, not rendering.
    func testPendingChunksBehindTheCurrentOneWait() {
        let chunks = [chunk(0, "ok"), chunk(1, "pending"), chunk(2, "pending")]
        let states = ReelScript.phraseStates(emitting: [true, true, true],
                                             chunks: chunks, paragraphOf: [0: 0, 1: 1, 2: 2])
        XCTAssertEqual(states, [.done, .rendering, .pending])
    }

    /// A phrase with no chunk yet is pending, and a phrase that emits none
    /// (a pause-only block) takes no paragraph number — the daemon's count
    /// skips it, so the next phrase maps to the next paragraph index.
    func testSilentPhrasesDoNotShiftTheParagraphNumbers() {
        let chunks = [chunk(0, "ok"), chunk(1, "pending")]
        let states = ReelScript.phraseStates(emitting: [true, false, true],
                                             chunks: chunks, paragraphOf: [0: 0, 1: 1])
        XCTAssertEqual(states, [.done, .pending, .rendering])
    }

    // MARK: R4 — the create button's inputs

    /// Mutation: ignore the running job -> RED.
    func testCreateNeedsTextTheEngineAndAnIdleDaemon() {
        XCTAssertTrue(ReelScript.canCreate(script: "Текст.", studioAvailable: true, jobRunning: false))
        XCTAssertFalse(ReelScript.canCreate(script: "   ", studioAvailable: true, jobRunning: false),
                       "an empty script cannot be voiced")
        XCTAssertFalse(ReelScript.canCreate(script: "Текст.", studioAvailable: false, jobRunning: false),
                       "no studio voice, no button")
        XCTAssertFalse(ReelScript.canCreate(script: "Текст.", studioAvailable: true, jobRunning: true),
                       "one project at a time")
    }

    func testAScriptOverTheLimitCannotBeVoiced() {
        let huge = String(repeating: "а", count: ScriptLimit.maxCharacters + 1)
        XCTAssertFalse(ReelScript.canCreate(script: huge, studioAvailable: true, jobRunning: false))
    }

    // MARK: what the editor shows

    /// The project title comes from the first phrase, line breaks folded;
    /// the daemon itself keeps the first 60 runes.
    func testTheTitleIsTheFirstPhrase() {
        XCTAssertEqual(ReelScript.title(of: "Первая фраза.\nвторая строка\n\nВторая фраза."),
                       "Первая фраза. вторая строка")
        XCTAssertEqual(ReelScript.title(of: "   \n\n"), "")
    }

    /// A row shows the phrase's start, folded and capped near 60 characters.
    func testTheRowPreviewIsShortAndFolded() {
        let long = String(repeating: "слово ", count: 30)
        let preview = ReelScript.preview(long)
        XCTAssertLessThanOrEqual(preview.count, ReelScript.previewLength + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(ReelScript.preview("короткая\nстрока"), "короткая строка")
    }

    func testTheDurationReadsAsClockTime() {
        XCTAssertEqual(ReelScript.durationText(0), "0:00")
        XCTAssertEqual(ReelScript.durationText(61.5), "1:01")
        XCTAssertEqual(ReelScript.durationText(3661), "1:01:01")
        XCTAssertNil(ReelScript.durationText(nil))
    }

    /// The reel's create is pinned to the plan: one take per chunk and the
    /// reference clone path.
    func testTheCreateIsOneTakeOfAReferenceVoice() {
        XCTAssertEqual(ReelScript.takes, 1)
        XCTAssertEqual(ReelScript.cloneMode, "reference")
    }
}
