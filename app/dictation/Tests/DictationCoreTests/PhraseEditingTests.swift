import XCTest
@testable import DictationCore

final class PhraseEditingTests: XCTestCase {
    func testAMoodIsSentAsItsWordAndNeverAsAnEmotionSlider() {
        XCTAssertEqual(PhraseEditing.style(for: .excited, custom: nil), "восторженно")
        XCTAssertEqual(PhraseEditing.style(for: nil, custom: "  устало  "), "устало")
        XCTAssertNil(PhraseEditing.style(for: nil, custom: "   "))
        XCTAssertNil(PhraseEditing.style(for: nil, custom: "(смеётся)"), "parentheses are read as a style tag by the engine")
    }

    func testEveryMoodHasItsRussianWord() {
        XCTAssertEqual(Mood.allCases.map(\.styleWord), ["спокойно", "тепло", "энергично", "восторженно", "серьёзно"])
    }

    func testVariantsCycleAndLabelInRussian() {
        XCTAssertEqual(PhraseEditing.nextPick(current: "a", keys: ["a", "b", "c"]), "b")
        XCTAssertEqual(PhraseEditing.nextPick(current: "c", keys: ["a", "b", "c"]), "a")
        XCTAssertEqual(PhraseEditing.variantLabel(index: 1, of: 3, text: ShippedStrings.localizer("ru")), "Вариант 2 из 3")
    }

    func testTextCannotBeEditedWhileTheProjectRuns() {
        XCTAssertFalse(PhraseEditing.canEditText(status: .running))
        XCTAssertTrue(PhraseEditing.canEditText(status: .done))
    }
}

private func chunk(_ n: Int, _ status: ProduceChunkState, text: String = "Фраза", style: String? = nil, pick: String? = nil,
                   keys: [String] = ["a"], files: [String: String] = [:]) -> ProduceChunkDetail {
    ProduceChunkDetail(index: n, paragraph: n, text: text, style: style, status: status, pick: pick, takeKeys: keys, takeFiles: files)
}

extension PhraseEditingTests {
    func testRowsShowDoneListenAndTheOneBeingRendered() {
        let rows = PhraseEditing.rows(chunks: [chunk(0, .ok), chunk(1, .review), chunk(2, .pending), chunk(3, .pending)], jobRunning: true)
        XCTAssertEqual(rows.map(\.state), [.done, .needsListen, .rendering, .pending])
    }

    func testNothingIsRenderingWhenTheProjectIsNotRunning() {
        let rows = PhraseEditing.rows(chunks: [chunk(0, .ok), chunk(1, .pending)], jobRunning: false)
        XCTAssertEqual(rows.map(\.state), [.done, .pending], "a stalled project must not claim a phrase is being made")
    }

    func testARowKnowsItsVariantItsMoodAndWhetherItCanPlay() {
        let rows = PhraseEditing.rows(chunks: [
            chunk(0, .ok, style: "тепло", pick: "b", keys: ["a", "b", "c"], files: ["b": "/t/b.wav"]),
            chunk(1, .ok, style: "устало", pick: nil, keys: ["a"], files: [:]),
        ], jobRunning: false)
        guard rows.count == 2 else { return XCTFail("two chunks, two rows, got \(rows.count)") }
        XCTAssertEqual([rows[0].variant, rows[0].variants], [1, 3])
        XCTAssertEqual(rows[0].mood, .warm)
        XCTAssertTrue(rows[0].playable)
        XCTAssertEqual([rows[1].variant, rows[1].variants], [0, 1])
        XCTAssertNil(rows[1].mood, "a style that is none of the five moods has no chip selected")
        XCTAssertEqual(rows[1].style, "устало")
        XCTAssertFalse(rows[1].playable)
    }

    func testARowPreviewDropsDirectives() {
        let rows = PhraseEditing.rows(chunks: [chunk(0, .ok, text: "[style: тепло] Привет, друг.")], jobRunning: false)
        guard let first = rows.first else { return XCTFail("one chunk, one row") }
        XCTAssertEqual(first.preview, "Привет, друг.")
    }

    func testChoosingNoMoodClearsTheStyleInsteadOfLeavingIt() {
        XCTAssertEqual(PhraseEditing.deliveryEntry(chunk: 3, mood: .excited), DeliveryEntry(n: 3, style: "восторженно"))
        XCTAssertEqual(PhraseEditing.deliveryEntry(chunk: 3, mood: nil), DeliveryEntry(n: 3, style: ""),
                       "a nil style is left alone by the daemon; only an empty one clears it")
    }

    func testThePlayedFileIsThePickedTake() {
        XCTAssertEqual(PhraseEditing.takeFile(of: chunk(0, .ok, pick: "b", keys: ["a", "b"], files: ["a": "/t/a.wav", "b": "/t/b.wav"])), "/t/b.wav")
        XCTAssertNil(PhraseEditing.takeFile(of: chunk(0, .ok, pick: nil, keys: ["a"], files: ["a": "/t/a.wav"])))
    }
}

/// The daemon's chunk operations launch a job; a second one is refused while it runs ("not one of this chunk's takes" is the
/// answer to a pick made before the new takes exist).
private final class FakeDaemon {
    var running = false
    var log: [String] = []
    var keys = ["a"]
    var addTake = true

    func steps() -> PhraseRegeneration.Steps {
        PhraseRegeneration.Steps(
            regenerate: { n in self.log.append("regenerate \(n)"); self.running = true },
            waitUntilIdle: { self.log.append("wait"); self.running = false; if self.addTake, !self.keys.contains("b") { self.keys.append("b") } },
            chunks: { self.log.append("chunks"); return [chunk(2, .ok, pick: "a", keys: self.keys)] },
            pick: { n, key in
                if self.running || !self.keys.contains(key) { throw StudioError.refused(status: 400, message: "take is not one of this chunk's takes") }
                self.log.append("pick \(n) \(key)")
                self.running = true
            })
    }
}

extension PhraseEditingTests {
    func testPickWaitsForTheRegenerateToFinish() async throws {
        let daemon = FakeDaemon()
        let after = try await PhraseRegeneration.run(chunk: 2, known: ["a"], steps: daemon.steps())
        XCTAssertEqual(daemon.log, ["regenerate 2", "wait", "chunks", "pick 2 b", "wait", "chunks"])
        XCTAssertEqual(after.count, 1)
    }

    func testNoNewTakeMeansNoPick() async throws {
        let daemon = FakeDaemon()
        daemon.addTake = false
        _ = try await PhraseRegeneration.run(chunk: 2, known: ["a"], steps: daemon.steps())
        XCTAssertEqual(daemon.log, ["regenerate 2", "wait", "chunks"])
    }

    func testAFailedRegenerateStopsBeforeAnythingElse() async {
        var log: [String] = []
        let steps = PhraseRegeneration.Steps(regenerate: { _ in throw StudioError.voiceoverRunning }, waitUntilIdle: { log.append("wait") },
                                             chunks: { log.append("chunks"); return [] }, pick: { _, _ in log.append("pick") })
        do { _ = try await PhraseRegeneration.run(chunk: 0, known: [], steps: steps); XCTFail("must throw") } catch {}
        XCTAssertEqual(log, [])
    }

    func testTheWaitEndsAtTheFirstTerminalStatus() async throws {
        var answers: [ProduceStatus] = [.running, .running, .done]
        var slept = 0
        let job = try await JobWait.untilTerminal(id: "p", poll: { _ in ProduceJob(id: "p", title: "", status: answers.removeFirst()) },
                                                  sleep: { _ in slept += 1 })
        XCTAssertEqual(job.status, .done)
        XCTAssertEqual(slept, 2)
    }

    func testTheWaitSurvivesAMissedPollAndGivesUpAtTheLimit() async throws {
        var polls = 0
        let job = try await JobWait.untilTerminal(id: "p", poll: { _ in
            polls += 1
            if polls == 1 { throw StudioError.daemonUnreachable }
            return ProduceJob(id: "p", title: "", status: .review)
        }, sleep: { _ in })
        XCTAssertEqual(job.status, .review)
        do {
            _ = try await JobWait.untilTerminal(id: "p", poll: { _ in ProduceJob(id: "p", title: "", status: .running) },
                                                sleep: { _ in }, maxPolls: 3)
            XCTFail("must give up")
        } catch {
            XCTAssertEqual(error as? JobWait.Failure, .gaveUp)
        }
    }
}

extension PhraseEditingTests {
    func testMoodChipsAreDrawnForADesignedVoiceAndHiddenOnACloneInTheSimpleMode() {
        let voices = [VoiceEntry(id: "made", label: "Made", kind: .designed("calm")),
                      VoiceEntry(id: "mine", label: "Mine", kind: .recorded)]
        XCTAssertTrue(PhraseEditing.showsMood(voice: "made", voices: voices, advanced: false))
        XCTAssertFalse(PhraseEditing.showsMood(voice: "mine", voices: voices, advanced: false))
        XCTAssertFalse(PhraseEditing.showsMood(voice: nil, voices: voices, advanced: false), "a project of an earlier session has no voice on record")
        XCTAssertFalse(PhraseEditing.showsMood(voice: "gone", voices: voices, advanced: false))
    }

    func testAdvancedDrawsMoodChipsForAnyVoice() {
        let voices = [VoiceEntry(id: "mine", label: "Mine", kind: .recorded)]
        XCTAssertTrue(PhraseEditing.showsMood(voice: "mine", voices: voices, advanced: true))
        XCTAssertTrue(PhraseEditing.showsMood(voice: nil, voices: voices, advanced: true))
    }
}
