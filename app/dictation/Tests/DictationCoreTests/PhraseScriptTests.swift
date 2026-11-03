import XCTest
@testable import DictationCore

/// The Озвучка editor's pure rules: how the script becomes phrases (the
/// daemon's paragraphs), how its chunks map back onto them, and when
/// "Озвучить" is live.
final class PhraseScriptTests: XCTestCase {
    // MARK: R1 — phrases are blank-line-separated paragraphs

    /// A multi-line paragraph stays one phrase; CRLF endings are the same
    /// line breaks as LF. Mutation: split on single newlines -> RED here.
    func testPhrasesAreBlankLineBlocks() {
        XCTAssertEqual(PhraseScript.phrases(of: "Один.\r\nДва.\r\n\r\nТри."), ["Один.\nДва.", "Три."])
    }

    func testSeveralBlankLinesAndWhitespaceOnlyLinesAreOneBreak() {
        XCTAssertEqual(PhraseScript.phrases(of: "Первый.\n\n\n   \n\t\nВторой."), ["Первый.", "Второй."])
    }

    func testASingleParagraphIsOnePhrase() {
        XCTAssertEqual(PhraseScript.phrases(of: "Только один абзац."), ["Только один абзац."])
    }

    func testATrailingBlankLineEndsTheLastPhrase() {
        XCTAssertEqual(PhraseScript.phrases(of: "Текст.\n\n"), ["Текст."])
    }

    /// A directive is text the daemon reads, not a split point; it stays
    /// inside its phrase, literal.
    func testAPauseDirectiveStaysInsideItsPhrase() {
        XCTAssertEqual(PhraseScript.phrases(of: "Стоп. [pause 1s]\n\nДальше."), ["Стоп. [pause 1s]", "Дальше."])
    }

    func testAPhraseIsTrimmedAndAnEmptyScriptHasNone() {
        XCTAssertEqual(PhraseScript.phrases(of: "  Текст.  \n\n   Ещё.   "), ["Текст.", "Ещё."])
        XCTAssertEqual(PhraseScript.phrases(of: " \n\n \t \n"), [])
    }

    /// The daemon counts only paragraphs that produce chunks: one of nothing
    /// but [pause …] emits none and does not take a paragraph number.
    /// Mutation: `emits` answers true for a pause-only paragraph -> RED here.
    func testAPauseOnlyPhraseEmitsNothing() {
        XCTAssertFalse(PhraseScript.emits("[pause 1s]"))
        XCTAssertFalse(PhraseScript.emits(" [pause 1s]\n[pause 300ms] "))
        XCTAssertTrue(PhraseScript.emits("Стоп. [pause 1s]"))
        XCTAssertTrue(PhraseScript.emits("[style: тепло]\nТекст."))
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
        let states = PhraseScript.phraseStates(emitting: [true, true, true], chunks: chunks, paragraphOf: paragraphs)
        XCTAssertEqual(states, [.done, .rendering, .pending])
    }

    /// A chunk the automatic checks could not pass ("review") marks its phrase
    /// for a listen — the daemon keeps its audio; the row is not a failure.
    func testAReviewChunkMarksItsPhraseForListening() {
        let chunks = [chunk(0, "ok"), chunk(1, "review")]
        let states = PhraseScript.phraseStates(emitting: [true], chunks: chunks, paragraphOf: [0: 0, 1: 0])
        XCTAssertEqual(states, [.needsListen])
    }

    /// The daemon renders chunks in order: pending chunks behind the one in
    /// flight are still pending, not rendering.
    func testPendingChunksBehindTheCurrentOneWait() {
        let chunks = [chunk(0, "ok"), chunk(1, "pending"), chunk(2, "pending")]
        let states = PhraseScript.phraseStates(emitting: [true, true, true],
                                             chunks: chunks, paragraphOf: [0: 0, 1: 1, 2: 2])
        XCTAssertEqual(states, [.done, .rendering, .pending])
    }

    /// A phrase with no chunk yet is pending, and a phrase that emits none
    /// (a pause-only block) takes no paragraph number — the daemon's count
    /// skips it, so the next phrase maps to the next paragraph index.
    func testSilentPhrasesDoNotShiftTheParagraphNumbers() {
        let chunks = [chunk(0, "ok"), chunk(1, "pending")]
        let states = PhraseScript.phraseStates(emitting: [true, false, true],
                                             chunks: chunks, paragraphOf: [0: 0, 1: 1])
        XCTAssertEqual(states, [.done, .pending, .rendering])
    }

    // MARK: R4 — the create button's inputs

    /// Mutation: ignore the running job -> RED.
    func testCreateNeedsTextTheEngineAndAnIdleDaemon() {
        XCTAssertTrue(PhraseScript.canCreate(script: "Текст.", studioAvailable: true, jobRunning: false))
        XCTAssertFalse(PhraseScript.canCreate(script: "   ", studioAvailable: true, jobRunning: false),
                       "an empty script cannot be voiced")
        XCTAssertFalse(PhraseScript.canCreate(script: "Текст.", studioAvailable: false, jobRunning: false),
                       "no studio voice, no button")
        XCTAssertFalse(PhraseScript.canCreate(script: "Текст.", studioAvailable: true, jobRunning: true),
                       "one project at a time")
    }

    func testAScriptOverTheLimitCannotBeVoiced() {
        let huge = String(repeating: "а", count: ScriptLimit.maxCharacters + 1)
        XCTAssertFalse(PhraseScript.canCreate(script: huge, studioAvailable: true, jobRunning: false))
    }

    // MARK: what the editor shows

    /// The project title comes from the first phrase, line breaks folded;
    /// the daemon itself keeps the first 60 runes.
    func testTheTitleIsTheFirstPhrase() {
        XCTAssertEqual(PhraseScript.title(of: "Первая фраза.\nвторая строка\n\nВторая фраза."),
                       "Первая фраза. вторая строка")
        XCTAssertEqual(PhraseScript.title(of: "   \n\n"), "")
    }

    /// A row shows the phrase's start, folded and capped near 60 characters.
    func testTheRowPreviewIsShortAndFolded() {
        let long = String(repeating: "слово ", count: 30)
        let preview = PhraseScript.preview(long)
        XCTAssertLessThanOrEqual(preview.count, PhraseScript.previewLength + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(PhraseScript.preview("короткая\nстрока"), "короткая строка")
    }

    /// The preview shows the words, not the directives: `[pause …]` and
    /// `[style: …]` are read by the daemon, and `emits` strips them with the
    /// same pattern (ScriptBrackets.directivePattern).
    /// Mutation: preview without the directive strip -> RED.
    func testTheRowPreviewDropsDirectiveText() {
        XCTAssertEqual(PhraseScript.preview("Стоп. [pause 1s]"), "Стоп.")
        XCTAssertEqual(PhraseScript.preview("[style: тепло]\nТекст."), "Текст.")
    }

    func testTheDurationReadsAsClockTime() {
        XCTAssertEqual(PhraseScript.durationText(0), "0:00")
        XCTAssertEqual(PhraseScript.durationText(61.5), "1:01")
        XCTAssertEqual(PhraseScript.durationText(3661), "1:01:01")
        XCTAssertNil(PhraseScript.durationText(nil))
    }

    // MARK: F1 — the chunks still missing a detail

    /// A job is synced only when every chunk index holds a paragraph; what is
    /// still missing is refetched on the next poll. Mutation: missingChunks
    /// answers [] for a partially-fetched job -> RED.
    func testMissingChunksNamesExactlyTheChunksWithoutAParagraph() {
        let job = ProduceJob(id: "j", title: "t", status: .running, partsTotal: 4)
        XCTAssertEqual(PhraseScript.missingChunks(of: job, paragraphOf: [0: 0, 2: 1]), [1, 3],
                       "a partial fetch leaves its failed indices missing")
        XCTAssertEqual(PhraseScript.missingChunks(of: job, paragraphOf: [:]), [0, 1, 2, 3])
        XCTAssertEqual(PhraseScript.missingChunks(of: job, paragraphOf: [0: 0, 1: 0, 2: 1, 3: 1]), [])
    }

    /// A detail under an index outside the job's range is not the job's; a job
    /// with no chunks needs no fetch.
    func testMissingChunksIgnoresStrayIndices() {
        let job = ProduceJob(id: "j", title: "t", status: .running, partsTotal: 2)
        XCTAssertEqual(PhraseScript.missingChunks(of: job, paragraphOf: [7: 0]), [0, 1])
        let empty = ProduceJob(id: "j", title: "t", status: .done, partsTotal: 0)
        XCTAssertEqual(PhraseScript.missingChunks(of: empty, paragraphOf: [:]), [])
    }

    // MARK: F3 — the export's destination rule

    /// A folder is refused: removing it to make room would delete a directory
    /// whole. Mutation: allow a directory destination -> RED.
    func testAFolderIsNeverAnExportDestination() {
        XCTAssertFalse(ExportRules.allowsDestination(isDirectory: true))
        XCTAssertTrue(ExportRules.allowsDestination(isDirectory: false))
    }

    /// The staged copy sits next to the destination — the swap stays on one
    /// volume, so `replaceItemAt` is atomic and a failed copy keeps the old file.
    func testTheStagingFileSitsNextToTheDestination() {
        let destination = URL(fileURLWithPath: "/tmp/out/reel.wav")
        let staging = ExportRules.stagingURL(for: destination)
        XCTAssertEqual(staging.deletingLastPathComponent(), destination.deletingLastPathComponent())
        XCTAssertNotEqual(staging, destination)
        XCTAssertTrue(staging.lastPathComponent.contains("reel.wav"))
    }
}
