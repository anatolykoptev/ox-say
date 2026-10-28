import Foundation
import XCTest
@testable import DictationCore

/// PR #261 review: the decisions the controller and recorder only carry out.
final class SystemAudioGuardRuleTests: XCTestCase {
    private func assess(callbacks: Int = 100, peak: Float = 0, elapsed: TimeInterval = 30, playingFor: TimeInterval = 0,
                        micLoudFor: TimeInterval = 0, heardLoud: Bool = false) -> SystemAudioGuard.Verdict {
        SystemAudioGuard.assess(.init(callbacks: callbacks, peak: peak, elapsed: elapsed, playingFor: playingFor,
                                      heardLoud: heardLoud, micLoudFor: micLoudFor))
    }

    /// A call app plays digital silence before the other side joins; auto-start begins 4 s after the mic opens, so in
    /// the first seconds zeros with a process "playing" are normal, not a broken permission.
    /// Mutation: SystemAudioGuard.playingBeforeVerdict, set it to 5 -> RED.
    func testDigitalSilenceEarlyInACallIsNotASilentTap() {
        for elapsed in stride(from: 5.0, through: 10.0, by: 1.0) {
            XCTAssertEqual(assess(elapsed: elapsed, playingFor: 5), .waiting, "elapsed \(elapsed)")
        }
        XCTAssertEqual(assess(elapsed: 19, playingFor: 15), .waiting)
    }

    func testTwentySecondsOfPlayingAndExactZerosIsTheSilentTap() {
        XCTAssertEqual(assess(elapsed: 25, playingFor: SystemAudioGuard.playingBeforeVerdict), .silentTap)
    }

    /// Somebody is talking on this side (the mic is loud for a while) while a process plays and the tap is exact zero.
    /// Mutation: SystemAudioGuard.assess, delete the `micLoudFor >= micLoudBeforeVerdict` clause -> RED.
    func testAMicTalkingWhileTheTapIsZeroIsTheSilentTap() {
        XCTAssertEqual(assess(elapsed: 12, playingFor: 6, micLoudFor: SystemAudioGuard.micLoudBeforeVerdict), .silentTap)
        XCTAssertEqual(assess(elapsed: 12, playingFor: 6, micLoudFor: 2), .waiting)
        XCTAssertEqual(assess(elapsed: 12, playingFor: 0, micLoudFor: 30), .waiting, "nothing plays: nothing to hear")
    }

    func testRealSamplesAreNeverASilentTap() {
        XCTAssertEqual(assess(peak: 0.0004, elapsed: 12, playingFor: 40, micLoudFor: 40), .waiting)
        XCTAssertEqual(assess(peak: 0.3, playingFor: 40, heardLoud: true), .fine)
    }

    /// The sentence names the whole path to the toggle, in both languages.
    /// Mutation: Localizable.strings notice.meeting.tap_silent, drop "System Audio Recording Only" -> RED.
    func testTheSilentTapSentenceNamesTheWholePathInBothLanguages() throws {
        let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let words: [String: [String]] = [
            "en": ["Privacy & Security", "Screen & System Audio Recording", "System Audio Recording Only", "off and on"],
            "ru": ["Конфиденциальность и безопасность", "Запись экрана и системного звука", "Только запись системного звука", "выключите и снова включите"],
        ]
        for (lang, needles) in words {
            let text = try String(contentsOf: res.appendingPathComponent("\(lang).lproj/Localizable.strings"), encoding: .utf8)
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("\"notice.meeting.tap_silent\"") }, lang)
            for needle in needles { XCTAssertTrue(line.contains(needle), "\(lang): \(needle)") }
        }
    }
}

final class RecordingMonitorTests: XCTestCase {
    private func tick(_ m: inout RecordingMonitor, elapsed: TimeInterval = 10, writeFailed: Bool = false, callbacks: Int = 100,
                      peak: Float = 0, playingFor: TimeInterval = 0, heardLoud: Bool = false, meLoud: Bool = false) -> [RecordingMonitor.Action] {
        m.observe(.init(elapsed: elapsed, writeFailed: writeFailed, callbacks: callbacks, peak: peak, playingFor: playingFor,
                        heardLoud: heardLoud, meLoud: meLoud, dt: 0.25))
    }

    /// Mutation: RecordingMonitor.observe, delete the writeFailed branch -> RED.
    func testTheFirstFailedWriteStops() {
        var m = RecordingMonitor()
        XCTAssertEqual(tick(&m, writeFailed: true), [.stop(.diskFull)])
    }

    /// Mutation: RecordingMonitor.observe, `reachedCap` -> `false` -> RED.
    func testTheCapStops() {
        var m = RecordingMonitor()
        XCTAssertEqual(tick(&m, elapsed: MeetingLimits.maxRecordingSeconds - 1, heardLoud: true), [])
        XCTAssertEqual(tick(&m, elapsed: MeetingLimits.maxRecordingSeconds), [.stop(.cap)])
    }

    /// Said once; a later tick says nothing.
    /// Mutation: RecordingMonitor.observe, delete `told.insert(.tapSilent).inserted` -> RED (said every tick).
    func testTheSilentTapIsSaidOnce() {
        var m = RecordingMonitor()
        XCTAssertEqual(tick(&m, elapsed: 25, playingFor: 20), [.say(.tapSilent)])
        XCTAssertEqual(tick(&m, elapsed: 26, playingFor: 21), [])
    }

    /// A talking microphone is counted by the monitor, tick by tick.
    /// Mutation: RecordingMonitor.observe, delete `micLoud += dt` -> RED.
    func testALoudMicrophoneAddsUpToTheVerdict() {
        var m = RecordingMonitor()
        var said: [RecordingMonitor.Action] = []
        for _ in 0..<60 { said += tick(&m, elapsed: 12, playingFor: 7, meLoud: true) }
        XCTAssertEqual(said, [.say(.tapSilent)])
    }

    func testAQuietMicrophoneNeverCounts() {
        var m = RecordingMonitor()
        var said: [RecordingMonitor.Action] = []
        for i in 0..<60 { said += tick(&m, elapsed: 6 + Double(i) * 0.1, playingFor: 7, meLoud: false) }
        XCTAssertEqual(said, [])
    }

    /// A tap that failed to start has been told; "nothing recorded" is not told again. After a recovery and a new
    /// failure the user hears about it.
    /// Mutation: RecordingMonitor.observe, drop the `!systemAudioFailed` condition -> RED.
    func testNoCallbacksIsNotToldOverAKnownFailure() {
        var m = RecordingMonitor()
        m.systemAudioFailed = true
        XCTAssertEqual(tick(&m, elapsed: 8, callbacks: 0), [])
        m.systemAudioFailed = false
        XCTAssertEqual(tick(&m, elapsed: 9, callbacks: 0), [.say(.noSystemAudio)])
        XCTAssertEqual(tick(&m, elapsed: 10, callbacks: 0), [])
    }

    func testAQuietOtherSideIsToldUnlessTheTapSilentSentenceWasSaid() {
        var m = RecordingMonitor()
        XCTAssertEqual(tick(&m, elapsed: 21, peak: 0.0002), [.say(.noSystemAudio)])
        var n = RecordingMonitor()
        XCTAssertEqual(tick(&n, elapsed: 25, playingFor: 20), [.say(.tapSilent)])
        XCTAssertEqual(tick(&n, elapsed: 26, peak: 0, playingFor: 0), [], "the silent-tap sentence already covers it")
    }
}

final class ReacquireTests: XCTestCase {
    /// 0.4, 1, 2, 4, then every 5 s.
    /// Mutation: Reacquire.delays, drop the 4 -> RED.
    func testBackoffThenAFixedPeriod() {
        var r = Reacquire()
        let delays = (0..<8).map { _ in r.failed().delay }
        XCTAssertEqual(delays, [0.4, 1, 2, 4, 5, 5, 5, 5])
    }

    /// The first failure of a streak is told; the retries are silent; a recovery is told; the next streak is told again.
    /// #266: a rebuild that failed while the OLD tap keeps recording does not tell "system audio lost", and its
    /// later success does not tell "recovered" either.
    /// Mutation: Reacquire.failed, drop `sourceLost &&` from `notify` -> RED.
    func testAFailureThatKeepsTheSourceIsNotToldNorItsRecovery() {
        var r = Reacquire()
        XCTAssertEqual(r.failed(sourceLost: false), Reacquire.Step(delay: 0.4, notify: false))
        XCTAssertEqual(r.failed(sourceLost: false), Reacquire.Step(delay: 1, notify: false))
        XCTAssertFalse(r.succeeded(), "nothing was told, so there is no recovery to tell")
    }

    /// Mutation: Reacquire.succeeded, `return told` -> `return attempts > 0` -> RED.
    func testAStreakThatWasToldIsRecoveredToldOnce() {
        var r = Reacquire()
        XCTAssertTrue(r.failed(sourceLost: true).notify)
        XCTAssertFalse(r.failed(sourceLost: false).notify)
        XCTAssertTrue(r.succeeded())
        XCTAssertFalse(r.succeeded())
        XCTAssertTrue(r.failed(sourceLost: true).notify, "a later streak is told again")
    }

    /// Mutation: Reacquire.failed, `notify: attempts == 0` -> `notify: true` -> RED.
    func testNoticesFollowTheStreak() {
        var r = Reacquire()
        XCTAssertTrue(r.failed().notify)
        XCTAssertFalse(r.failed().notify)
        XCTAssertFalse(r.failed().notify)
        XCTAssertTrue(r.succeeded(), "recovered after failing")
        XCTAssertFalse(r.succeeded(), "a success with nothing to recover from says nothing")
        XCTAssertTrue(r.failed().notify, "a later failure is told again")
        XCTAssertEqual(r.failed().delay, 1)
        _ = r.succeeded()
        XCTAssertEqual(r.failed().delay, 0.4, "the backoff starts over after a recovery")
    }
}

final class EngineStartTests: XCTestCase {
    /// The one long-lived AVAudioEngine raises an uncatchable exception when a tap is installed on a bus that has one.
    /// A fake with that rule: a failed start must remove its tap, and a start must clear a leftover.
    private final class FakeBus {
        var tapInstalled = false
        var crashes = 0
        func install() { if tapInstalled { crashes += 1 }; tapInstalled = true }
        func remove() { tapInstalled = false }
    }
    private struct Boom: Error {}

    /// Mutation: EngineStart.start, delete the `removeTap()` in the catch -> RED (the retry installs over the first tap).
    func testARetryAfterAFailedStartDoesNotInstallOverTheOldTap() {
        let bus = FakeBus()
        var fail = true
        XCTAssertThrowsErrorShim { try EngineStart.start(removeTap: bus.remove, installTap: bus.install, start: { if fail { throw Boom() } }) }
        XCTAssertFalse(bus.tapInstalled, "a failed start leaves no tap on the bus")
        fail = false
        XCTAssertNoThrowShim { try EngineStart.start(removeTap: bus.remove, installTap: bus.install, start: { if fail { throw Boom() } }) }
        XCTAssertEqual(bus.crashes, 0)
        XCTAssertTrue(bus.tapInstalled)
    }

    /// Mutation: EngineStart.start, delete the `removeTap()` before `installTap()` -> RED.
    func testAStartClearsALeftoverTap() {
        let bus = FakeBus()
        bus.tapInstalled = true
        XCTAssertNoThrowShim { try EngineStart.start(removeTap: bus.remove, installTap: bus.install, start: {}) }
        XCTAssertEqual(bus.crashes, 0)
    }
}

/// The shim has neither XCTAssertThrowsError nor XCTAssertNoThrow.
private extension XCTestCase {
    func XCTAssertThrowsErrorShim(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); XCTFail("did not throw", file: file, line: line) } catch {}
    }
    func XCTAssertNoThrowShim(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body() } catch { XCTFail("threw \(error)", file: file, line: line) }
    }
}

final class RetryTests: XCTestCase {
    /// The self-pid process object is not always there at once; a few short retries, then give up and say so.
    /// Mutation: Retry.firstNonNil, make it try once -> RED.
    func testFirstNonNilRetriesBriefly() {
        var calls = 0
        var waits = 0
        let got: Int? = Retry.firstNonNil(attempts: 3, wait: { waits += 1 }) { calls += 1; return calls == 3 ? 7 : nil }
        XCTAssertEqual(got, 7)
        XCTAssertEqual(waits, 2)
        var never = 0
        let none: Int? = Retry.firstNonNil(attempts: 3, wait: {}) { never += 1; return nil }
        XCTAssertNil(none)
        XCTAssertEqual(never, 3)
    }
}

final class MeetingPolicyTests: XCTestCase {
    /// Turning auto-start off mid-call must not orphan an auto recording's silence auto-stop.
    /// Mutation: MeetingPolicy.watcherShouldRun, drop `|| recording == .auto` -> RED.
    func testTheWatcherKeepsRunningUnderAnAutoRecording() {
        XCTAssertTrue(MeetingPolicy.watcherShouldRun(autoStart: false, recording: .auto))
        XCTAssertFalse(MeetingPolicy.watcherShouldRun(autoStart: false, recording: .manual))
        XCTAssertFalse(MeetingPolicy.watcherShouldRun(autoStart: false, recording: nil))
        XCTAssertTrue(MeetingPolicy.watcherShouldRun(autoStart: true, recording: nil))
    }

    /// An auto-start while an update installs would be ended by the relaunch: it is offered instead.
    /// Mutation: MeetingPolicy.onCallStarted, delete `!installing` -> RED.
    func testNoAutoStartWhileAnUpdateInstalls() {
        let auto: Set<String> = ["zoom"]
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "zoom", autoStart: true, autoSources: auto, installing: false), .start)
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "zoom", autoStart: true, autoSources: auto, installing: true), .prompt)
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "discord", autoStart: true, autoSources: auto, installing: false), .prompt)
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "zoom", autoStart: false, autoSources: auto, installing: false), .prompt)
    }

    /// A manual start during an install asks the user to wait.
    /// Mutation: MeetingPolicy.manualStart, return .go always -> RED.
    func testAManualStartWaitsForTheInstall() {
        XCTAssertEqual(MeetingPolicy.manualStart(installing: true), .waitForInstall)
        XCTAssertEqual(MeetingPolicy.manualStart(installing: false), .go)
    }
}

final class ReconcileTests: XCTestCase {
    private func act(_ status: MeetingInfo.Status, pending: String? = nil, exported: Bool = false, notes: Bool = false,
                     id: String = "a", current: String? = nil) -> Reconcile.Action {
        Reconcile.action(for: MeetingInfo(id: id, status: status, notesPending: pending), exported: exported ? [id] : [],
                         notesAvailable: notes, currentID: current)
    }

    /// A meeting still "recording" at launch (the app died) is tracked, so its export and notification happen now.
    /// Mutation: Reconcile.action, delete `.recording` from the track list -> RED.
    func testAMeetingStillRecordingAtLaunchIsTracked() {
        XCTAssertEqual(act(.recording), .track)
    }

    /// ...but never the one this session is recording right now.
    /// Mutation: Reconcile.action, delete the `info.id != currentID` guard -> RED.
    func testTheLiveRecordingIsNotReconciled() {
        XCTAssertEqual(act(.recording, current: "a"), .skip)
    }

    func testTheRest() {
        XCTAssertEqual(act(.queued), .track)
        XCTAssertEqual(act(.summarizing), .track)
        XCTAssertEqual(act(.done), .track)
        XCTAssertEqual(act(.done, exported: true), .skip)
        XCTAssertEqual(act(.transcribed, pending: "model_missing"), .skip)
        XCTAssertEqual(act(.transcribed, pending: "model_missing", notes: true), .retryNotesThenTrack)
        XCTAssertEqual(act(.transcribed), .track)
        XCTAssertEqual(act(.transcribed, exported: true), .skip)
        XCTAssertEqual(act(.failed), .skip)
    }
}

final class StatusIconStyleTests: XCTestCase {
    /// The red tint follows BOTH the dictation state and the meeting recording; one used to wipe the other.
    /// Mutation: StatusIconStyle.style, `dictationRecording || meetingRecording` -> `dictationRecording` -> RED.
    func testTheTintFollowsDictationAndMeetingRecording() {
        XCTAssertTrue(StatusIconStyle.style(meetingRecording: true, dictationRecording: false, dictationSymbol: "mic").red)
        XCTAssertTrue(StatusIconStyle.style(meetingRecording: false, dictationRecording: true, dictationSymbol: "mic.fill").red)
        XCTAssertTrue(StatusIconStyle.style(meetingRecording: true, dictationRecording: true, dictationSymbol: "mic.fill").red)
        XCTAssertFalse(StatusIconStyle.style(meetingRecording: false, dictationRecording: false, dictationSymbol: "mic").red)
    }

    func testTheMeetingDotWinsTheSymbol() {
        XCTAssertEqual(StatusIconStyle.style(meetingRecording: true, dictationRecording: false, dictationSymbol: "mic").symbol, "record.circle.fill")
        XCTAssertEqual(StatusIconStyle.style(meetingRecording: false, dictationRecording: true, dictationSymbol: "mic.fill").symbol, "mic.fill")
    }
}
