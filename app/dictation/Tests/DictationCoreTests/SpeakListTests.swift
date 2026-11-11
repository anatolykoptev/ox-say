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

final class SpeakListFreshnessTests: XCTestCase {
    private func job(_ status: ProduceStatus, done: Int = 0, id: String = "20261001-000000-aaaaaa") -> ProduceJob {
        ProduceJob(id: id, title: "t", status: status, partsTotal: 5, partsDone: done)
    }

    func testAFinishedFollowerCopyNeverOverridesTheDaemonsNewerEntry() {
        // The follower saw the job done; a resume through MCP made the daemon's entry running again.
        let listed = job(.running, done: 1)
        XCTAssertEqual(SpeakList.afterRead(projects: [listed], followed: job(.done, done: 5)), [listed])
        XCTAssertEqual(SpeakList.afterRead(projects: [listed], followed: job(.review, done: 5)), [listed])
        XCTAssertEqual(SpeakList.afterRead(projects: [listed], followed: job(.failed)), [listed])
    }

    func testAWorkingFollowerCopyIsFresherThanTheRead() {
        let listed = job(.running, done: 1)
        XCTAssertEqual(SpeakList.afterRead(projects: [listed], followed: job(.running, done: 3)).map(\.partsDone), [3])
        XCTAssertEqual(SpeakList.afterRead(projects: [listed], followed: nil), [listed])
    }

    func testASelectionThatVanishedIsSeenAsGone() {
        let p = job(.done)
        let clip = SpeakClip(id: "c", title: "", text: "", voice: nil, seconds: 1, wav: Data(), created: Date())
        XCTAssertTrue(SpeakList.stillPresent(nil, projects: [], clips: []))
        XCTAssertTrue(SpeakList.stillPresent(p.id, projects: [p], clips: []))
        XCTAssertTrue(SpeakList.stillPresent("c", projects: [], clips: [clip]))
        XCTAssertFalse(SpeakList.stillPresent(p.id, projects: [], clips: [clip]))
    }

    func testTheTrackKeyChangesWhenTheFileDoes() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        let base = SpeakTrack.key(projectID: "j", path: "/x/out.wav", modified: t0, size: 100)
        XCTAssertEqual(base, SpeakTrack.key(projectID: "j", path: "/x/out.wav", modified: t0, size: 100))
        XCTAssertNotEqual(base, SpeakTrack.key(projectID: "j", path: "/x/out.wav", modified: t1, size: 100), "a re-render rewrites the file")
        XCTAssertNotEqual(base, SpeakTrack.key(projectID: "j", path: "/x/out.wav", modified: t0, size: 101))
        XCTAssertNotEqual(base, SpeakTrack.key(projectID: "j", path: "/x/out.wav", modified: nil, size: nil), "a missing file has its own key")
    }

    func testASupersededStudioStartNeverLeavesStopDisabled() {
        var generation = Generation()
        var gate = StartingGate()
        XCTAssertFalse(gate.isActive(in: generation))
        gate.begin(generation.advance())
        XCTAssertTrue(gate.isActive(in: generation))
        generation.advance()          // a newer request owns the page now
        XCTAssertFalse(gate.isActive(in: generation), "the flag belonged to the request that was superseded")
        gate.begin(generation.advance())
        gate.end()
        XCTAssertFalse(gate.isActive(in: generation))
    }

    /// The notification is skipped only while the window shows this very project right now: the app is active, the window is
    /// on screen, Озвучка is the section and this job is the open one. Read at the moment it finishes, not at the start.
    func testTheFinishNoticeIsSkippedOnlyWhileTheWindowShowsThatProject() {
        let id = "20261110-101500-abc123"
        func shown(active: Bool = true, visible: Bool = true, section: MainSection? = .speak, speak: String? = id) -> ShownWindow {
            ShownWindow(appActive: active, windowVisible: visible, section: section, speakID: speak)
        }
        XCTAssertTrue(FinishNotice.windowShows(jobID: id, shown()), "the one suppressing case")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(section: .voices)), "another section")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(section: nil)), "no window")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(speak: "other")), "another project is open")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(speak: nil)), "a clip or nothing is open")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(active: false)), "another app is in front")
        XCTAssertFalse(FinishNotice.windowShows(jobID: id, shown(visible: false)), "minimised, covered, closed or on another Space")
    }
}
