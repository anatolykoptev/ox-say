import Foundation
import XCTest
@testable import DictationCore

final class VoiceDesignFlowTests: XCTestCase {
    private func take(_ n: Int) -> DesignTake { DesignTake(path: "/t/\(n).wav", durationSeconds: 6, suggestedName: "voice-\(n)", warning: nil) }
    private func reviewing() -> VoiceDesignFlow {
        var f = VoiceDesignFlow(description: "спокойный диктор", sentence: DesignForm.defaultSentence, label: "")
        _ = f.submit(taken: [])
        f.designed([take(1), take(2), take(3)])
        return f
    }
    private let en = ShippedStrings.localizer("en")

    func testAnEmptyDescriptionIsRefusedAndTheTextIsKept() {
        var f = VoiceDesignFlow(description: "", sentence: "Привет", label: "Диктор")
        XCTAssertNil(f.submit(taken: []))
        XCTAssertEqual(f.phase, .form)
        XCTAssertNotNil(f.problem)
        XCTAssertEqual(f.label, "Диктор")
    }
    /// Mutation F1: VoiceDesignFlow.submit, the `guard phase == .form` removed -> RED.
    func testASecondSubmitWhileDesigningDoesNothing() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        XCTAssertEqual(f.submit(taken: []), .design("диктор", "Привет"))
        XCTAssertNil(f.submit(taken: []))
    }
    /// Mutation F2: VoiceDesignFlow.next, `index = (index + 1) % takes.count` -> `index + 1` -> RED.
    func testReviewStartsOnTheFirstTakeAndNextWraps() {
        var f = reviewing()
        XCTAssertEqual(f.phase, .reviewing(index: 0))
        _ = f.next(); _ = f.next()
        XCTAssertEqual(f.next(), .play(take(1)))
        XCTAssertEqual(f.phase, .reviewing(index: 0))
    }
    func testKeepDerivesAnIdFromTheLabelOrTheSuggestion() {
        var f = reviewing(); f.label = "Мой диктор"
        XCTAssertEqual(f.keep(), .save(id: "moy-diktor", label: "Мой диктор", take: "/t/1.wav", replace: false))
        var g = reviewing()
        XCTAssertEqual(g.keep(), .save(id: "voice-1", label: "", take: "/t/1.wav", replace: false))
    }
    func testATakenNameAsksBeforeReplacingAndNoReturnsToTheSameTake() {
        var f = reviewing(); _ = f.next(); _ = f.keep()
        f.saveAnswered(.nameTaken)
        XCTAssertNotNil(f.confirmReplace)
        XCTAssertNil(f.confirmReplaceAnswered(false))
        XCTAssertEqual(f.phase, .reviewing(index: 1))
        _ = f.keep(); f.saveAnswered(.nameTaken)
        XCTAssertEqual(f.confirmReplaceAnswered(true), .save(id: "voice-2", label: "", take: "/t/2.wav", replace: true))
    }
    func testCancelAlwaysStopsPlaybackAndKeepsTheTypedText() {
        var f = reviewing()
        XCTAssertEqual(f.cancel(), .stopPlayback)
        XCTAssertEqual(f.phase, .form)
        XCTAssertEqual(f.description, "спокойный диктор")
    }
    func testIsBusyUntilTheFlowEnds() {
        var f = reviewing(); XCTAssertTrue(f.isBusy)
        _ = f.cancel(); XCTAssertFalse(f.isBusy)
    }

    // MARK: beyond the plan's list

    func testEveryPhaseSaysWhetherTheDesignIsWork() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        XCTAssertFalse(f.isBusy, "the form")
        _ = f.submit(taken: []); XCTAssertTrue(f.isBusy, "designing")
        f.designed([take(1)]); XCTAssertTrue(f.isBusy, "reviewing")
        _ = f.keep(); XCTAssertTrue(f.isBusy, "saving")
        f.saveAnswered(.saved(SavedVoice(name: "voice-1", notice: nil)))
        XCTAssertEqual(f.phase, .done(savedAs: "voice-1")); XCTAssertFalse(f.isBusy, "done")
        var g = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        _ = g.submit(taken: []); g.fail("x"); XCTAssertFalse(g.isBusy, "failed")
    }
    func testALabelThatNamesAnExistingVoiceIsRefusedByIdOrByLabel() {
        var byID = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "Мой диктор")
        XCTAssertNil(byID.submit(taken: ["moy-diktor"], text: en))
        XCTAssertEqual(byID.problem, en(.designProblemNameTaken))
        XCTAssertEqual(byID.phase, .form)
        var byLabel = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "МОЙ ДИКТОР")
        XCTAssertNil(byLabel.submit(taken: ["мой диктор"]), "a label already in the library, any case")
        var free = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "Мой диктор")
        XCTAssertNotNil(free.submit(taken: ["other"]))
    }
    func testALabelTheDaemonWouldRefuseIsRefusedHere() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "a\nb")
        XCTAssertNil(f.submit(taken: [], text: en))
        XCTAssertEqual(f.problem, en(.voicesRenameInvalid))
        var long = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: String(repeating: "я", count: VoiceLabel.maxChars + 1))
        XCTAssertNil(long.submit(taken: []))
    }
    func testAFormProblemClearsOnTheNextGoodSubmit() {
        var f = VoiceDesignFlow(description: "", sentence: "Привет", label: "")
        XCTAssertNil(f.submit(taken: []))
        f.description = "диктор"
        XCTAssertNotNil(f.submit(taken: []))
        XCTAssertNil(f.problem)
    }
    func testTheSuggestedIdAvoidsAVoiceThatExists() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        _ = f.submit(taken: ["voice-1"])
        f.designed([take(1)])
        XCTAssertEqual(f.keep(), .save(id: "voice-1-2", label: "", take: "/t/1.wav", replace: false))
    }
    func testTheLabelSentIsTheCleanedOne() {
        var f = reviewing(); f.label = "  Диктор  "
        XCTAssertEqual(f.keep(), .save(id: "diktor", label: "Диктор", take: "/t/1.wav", replace: false))
    }
    func testReplayPlaysTheTakeUnderReview() {
        var f = reviewing(); _ = f.next()
        XCTAssertEqual(f.replay(), .play(take(2)))
        XCTAssertEqual(f.phase, .reviewing(index: 1))
        XCTAssertEqual(f.currentTake, take(2))
    }
    func testTakesThatArriveAfterACancelAreDropped() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        _ = f.submit(taken: [])
        _ = f.cancel()
        f.designed([take(1)])
        XCTAssertEqual(f.phase, .form)
        XCTAssertTrue(f.takes.isEmpty)
    }
    func testAnAnswerWithNoTakesIsAFailureNotAnEmptyReview() {
        var f = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        _ = f.submit(taken: [])
        f.designed([])
        guard case .failed = f.phase else { return XCTFail("\(f.phase)") }
    }
    func testAFailedDesignGoesBackToTheFormAndAFailedSaveBackToTheSameTake() {
        var d = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        _ = d.submit(taken: [])
        d.fail("no engine")
        XCTAssertEqual(d.phase, .failed("no engine"))
        d.acknowledgeFailure()
        XCTAssertEqual(d.phase, .form)
        XCTAssertEqual(d.description, "диктор")

        var s = reviewing(); _ = s.next(); _ = s.keep()
        s.fail("disk full")
        s.acknowledgeFailure()
        XCTAssertEqual(s.phase, .reviewing(index: 1))
    }
    func testASavedVoiceEndsTheFlowAndTheNextOneStartsFromTheSameText() {
        var f = reviewing(); f.label = "Мой диктор"
        _ = f.keep()
        f.saveAnswered(.saved(SavedVoice(name: "moy-diktor", notice: nil)))
        _ = f.cancel()
        XCTAssertEqual(f.description, "спокойный диктор")
        XCTAssertEqual(f.label, "", "a label names one voice")
    }

    /// Esc closes the sheet (and says so with `.stopPlayback`) except where closing would strand work: a save in
    /// flight, a replace question (Esc answers No) and a failure (Esc reads it).
    func testEscClosesTheSheetOnlyWhereClosingIsSafe() {
        var review = reviewing()
        XCTAssertEqual(review.escape(), .stopPlayback)
        XCTAssertEqual(review.phase, .form)
        var form = VoiceDesignFlow(description: "диктор", sentence: "Привет", label: "")
        XCTAssertEqual(form.escape(), .stopPlayback)

        var saving = reviewing(); _ = saving.keep()
        XCTAssertNil(saving.escape(), "a save in flight is not abandoned")
        XCTAssertEqual(saving.phase, .saving)

        var asking = reviewing(); _ = asking.keep(); asking.saveAnswered(.nameTaken)
        XCTAssertNil(asking.escape(), "Esc on the replace question is No")
        XCTAssertEqual(asking.phase, .reviewing(index: 0))
        XCTAssertNil(asking.confirmReplace)

        var failed = reviewing(); _ = failed.keep(); failed.fail("disk full")
        XCTAssertNil(failed.escape(), "Esc reads a failure")
        XCTAssertEqual(failed.phase, .reviewing(index: 0))
    }
}

final class DesignAvailabilityTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")

    func testTheStudioVoiceDecidesTheButton() {
        XCTAssertEqual(DesignAvailability.of(DaemonStatus(version: "v1", studioAvailable: true)), .available)
        XCTAssertEqual(DesignAvailability.of(DaemonStatus(version: "v1", studioAvailable: false, studioReasonCode: "model_missing")), .installable)
    }
    func testAMacThatCannotRunItGetsTheDaemonsReason() {
        let status = DaemonStatus(version: "v1", studioAvailable: false, studioReason: "Needs Apple Silicon with 24 GB.", studioReasonCode: "unsupported")
        XCTAssertEqual(DesignAvailability.of(status), .unavailable("Needs Apple Silicon with 24 GB."))
    }
    func testNoAnswerFromTheDaemonDisablesItWithAReason() {
        XCTAssertEqual(DesignAvailability.of(nil, text: en), .unavailable(en(.studioNoService)))
    }
}
