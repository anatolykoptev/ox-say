import XCTest
@testable import DictationCore

private let iso = ISO8601DateFormatter()
private func clip(_ id: String, _ stamp: String) -> SpeakClip {
    SpeakClip(id: id, title: "clip", text: "t", voice: nil, seconds: 3, wav: Data(), created: iso.date(from: stamp)!)
}

final class SpeakListTests: XCTestCase {
    func testIdTimestampBecomesTheCreationDate() {
        let job = ProduceJob(id: "20261015-120000-a1b2c3", title: "t", status: .done)
        XCTAssertEqual(job.createdAt, iso.date(from: "2026-10-15T12:00:00Z"))
        XCTAssertNil(ProduceJob(id: "garbage", title: "", status: .done).createdAt)
        XCTAssertNil(ProduceJob(id: "20261345-120000-a1b2c3", title: "", status: .done).createdAt, "month 13 is not a date")
    }

    func testARunningProjectStaysOnTopAndTheRestIsNewestFirst() {
        let running = ProduceJob(id: "20261001-000000-aaaaaa", title: "old but running", status: .running)
        let done = ProduceJob(id: "20261020-000000-bbbbbb", title: "new", status: .done)
        let list = SpeakList.merge(projects: [done, running], clips: [clip("c", "2026-10-25T00:00:00Z")])
        XCTAssertEqual(list.map(\.id), [running.id, "c", done.id])
    }

    func testEveryActiveStatusCountsAsRunning() {
        for status in [ProduceStatus.running, .waitingForDictation, .pausedOnBattery, .unknown("later")] {
            let job = ProduceJob(id: "20260101-000000-aaaaaa", title: "", status: status)
            let newer = ProduceJob(id: "20261201-000000-bbbbbb", title: "", status: .done)
            XCTAssertEqual(SpeakList.merge(projects: [newer, job], clips: []).first?.id, job.id, "\(status)")
            XCTAssertEqual(SpeakList.merge(projects: [job], clips: []).first?.state, .running)
        }
    }

    func testRowStateAndLengthFollowTheJob() {
        func item(_ job: ProduceJob) -> SpeakListItem { SpeakList.merge(projects: [job], clips: []).first! }
        let id = "20261001-000000-aaaaaa"
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .done, durationS: 61)).state, .ready)
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .done, durationS: 61)).seconds, 61)
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .review, partsToReview: 2)).state, .review)
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .failed)).state, .failed)
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .done, error: "x")).state, .failed,
                       "a done job that carries an error is not a saved result")
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .interrupted)).state, .interrupted)
        XCTAssertEqual(item(ProduceJob(id: id, title: "", status: .cancelled)).state, .stopped)
        XCTAssertEqual(SpeakList.merge(projects: [], clips: [clip("c", "2026-10-25T00:00:00Z")]).first?.state, .ready)
    }

    func testTheFollowedJobIsFresherThanTheListedOne() {
        let listed = ProduceJob(id: "20261001-000000-aaaaaa", title: "t", status: .running, partsTotal: 5, partsDone: 1)
        let followed = ProduceJob(id: listed.id, title: "t", status: .running, partsTotal: 5, partsDone: 3)
        let other = ProduceJob(id: "20260901-000000-bbbbbb", title: "o", status: .done)
        XCTAssertEqual(SpeakList.overlay(projects: [listed, other], followed: followed).map(\.partsDone), [3, 0])
        let fresh = ProduceJob(id: "20261101-000000-cccccc", title: "n", status: .running)
        XCTAssertEqual(SpeakList.overlay(projects: [listed], followed: fresh).map(\.id), [fresh.id, listed.id],
                       "a job started a moment ago shows before the next list read")
        XCTAssertEqual(SpeakList.overlay(projects: [listed], followed: nil), [listed])
    }
}

final class SpeakProjectStateTests: XCTestCase {
    private let t: (L10nKey) -> String = { $0.rawValue }
    private func state(_ job: ProduceJob, waiting: Bool = false, missing: Bool = false) -> SpeakProjectState {
        SpeakProjectState.of(job, serviceWaiting: waiting, trackMissing: missing, t)
    }

    func testARunningProjectShowsItsProgressRowAndADeterminateFraction() {
        let job = ProduceJob(id: "j", title: "Ch", status: .running, partsTotal: 5, partsDone: 3)
        guard case .running(let label, let fraction) = state(job) else { return XCTFail("running") }
        XCTAssertEqual(label, SpeakText.progressRow(job, serviceWaiting: false, t))
        XCTAssertEqual(fraction, 0.6)
        guard case .running(_, let none) = state(ProduceJob(id: "j", title: "", status: .running)) else { return XCTFail("running") }
        XCTAssertNil(none, "no part count yet: an indeterminate bar, never 0 of 0")
    }

    func testOneMissedPollMarksTheNumbersOldInsteadOfReplacingThem() {
        let job = ProduceJob(id: "j", title: "Ch", status: .running, partsTotal: 5, partsDone: 3)
        guard case .running(let label, let fraction) = state(job, waiting: true) else { return XCTFail("running") }
        XCTAssertTrue(label.contains(L10nKey.speakProgressWaiting.rawValue))
        XCTAssertEqual(fraction, 0.6, "the bar keeps the last known value")
    }

    func testAFinishedProjectOffersItsTrackAndAMissingFileSaysSo() {
        let done = ProduceJob(id: "j", title: "Ch", status: .done, outputPath: "/x/out.wav", durationS: 90)
        XCTAssertEqual(state(done), .ready(note: nil, seconds: 90))
        XCTAssertEqual(state(done, missing: true), .trackMissing)
        let review = ProduceJob(id: "j", title: "Ch", status: .review, partsToReview: 2, outputPath: "/x/out.wav", durationS: 90)
        guard case .ready(let note?, _) = state(review) else { return XCTFail("review keeps the track and says what to listen to") }
        XCTAssertEqual(note, SpeakText.finishText(review, t))
        XCTAssertEqual(state(ProduceJob(id: "j", title: "", status: .done)), .trackMissing, "done without an output path has no track")
    }

    func testEndedProjectsSaySoInTheirOwnWords() {
        XCTAssertEqual(state(ProduceJob(id: "j", title: "", status: .interrupted)), .ended(L10nKey.speakProjectInterrupted.rawValue),
                       "not the menu's sentence: a project has no «Озвучить» button to restart from")
        XCTAssertEqual(state(ProduceJob(id: "j", title: "", status: .cancelled)), .ended(L10nKey.speakProgressStopped.rawValue))
        guard case .ended(let sentence) = state(ProduceJob(id: "j", title: "", status: .failed, error: "engine exploded")) else { return XCTFail("failed") }
        XCTAssertTrue(sentence.contains(L10nKey.speakServiceAnswered.rawValue), "the daemon's reason rides behind the lead-in")
        guard case .ended = state(ProduceJob(id: "j", title: "", status: .done, error: "x", outputPath: "/x.wav")) else { return XCTFail("done with an error is a failure") }
    }
}

final class SpeakListRowTests: XCTestCase {
    private let t: (L10nKey) -> String = { $0.rawValue }
    private func row(_ job: ProduceJob) -> String { SpeakList.merge(projects: [job], clips: []).first!.status(t) }

    func testRowStatusLines() {
        let id = "20261001-000000-aaaaaa"
        XCTAssertEqual(row(ProduceJob(id: id, title: "", status: .running, partsTotal: 5, partsDone: 3)),
                       String(format: L10nKey.speakProgressParts.rawValue, 3, 5))
        XCTAssertEqual(row(ProduceJob(id: id, title: "", status: .running)), L10nKey.speakProgressStarting.rawValue)
        XCTAssertEqual(row(ProduceJob(id: id, title: "", status: .done, durationS: 75)), "1:15")
        XCTAssertEqual(row(ProduceJob(id: id, title: "", status: .review, partsToReview: 1, durationS: 75)), "1:15 · \(L10nKey.speakNeedsListen.rawValue)")
    }

    func testTheFollowerSaysWhetherAJobIsStillWorking() {
        let follower = VoiceoverFollower(source: .init(voiceover: { _ in throw StudioError.badResponse }, voiceovers: { [] }), onChange: {}, onFinish: { _ in })
        XCTAssertFalse(follower.following)
        follower.follow(ProduceJob(id: "j", title: "", status: .running))
        XCTAssertTrue(follower.following)
        follower.stop()
    }
}
