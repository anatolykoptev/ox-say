import Foundation
import XCTest
@testable import DictationCore

/// A player that behaves like Music: pause/play flip its state, and a counter
/// per call shows who was touched.
final class FakeMediaPlayer: MediaPlayer {
    let identifier: String
    var current: MediaPlaybackState
    private(set) var pauseCalls = 0
    private(set) var playCalls = 0
    /// When set, `state()` waits on it (up to a second) like a player that
    /// answers slowly.
    var gate: DispatchSemaphore?

    init(_ identifier: String, _ state: MediaPlaybackState) {
        self.identifier = identifier
        current = state
    }

    func state() -> MediaPlaybackState {
        _ = gate?.wait(timeout: .now() + 1)
        return current
    }
    func pause() { pauseCalls += 1; current = .paused }
    func play() { playCalls += 1; current = .playing }
}

final class MediaPauseCoordinatorTests: XCTestCase {
    // F1 — journey: music playing, the key goes down, it pauses; the key goes
    // up, it resumes. Mutation: in MediaPauseCoordinator.end drop the
    // `where owner[player.identifier] == generation` filter -> the user's own
    // pause below is undone (testResumesOnlyThePlayersItPaused goes RED).
    func testPlayingMusicPausesOnStartAndResumesOnEnd() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.begin(generation: 1)
        XCTAssertEqual(music.current, .paused, "the microphone must not hear the music")
        coordinator.end(generation: 1)
        XCTAssertEqual(music.current, .playing, "the music must come back")
        XCTAssertEqual([music.pauseCalls, music.playCalls], [1, 1])
    }

    func testResumesOnlyThePlayersItPaused() {
        let music = FakeMediaPlayer("music", .playing)
        let spotify = FakeMediaPlayer("spotify", .paused) // the user paused it earlier
        let coordinator = MediaPauseCoordinator(players: [music, spotify])
        coordinator.begin(generation: 1)
        coordinator.end(generation: 1)
        XCTAssertEqual(music.current, .playing)
        XCTAssertEqual(spotify.current, .paused, "a player the user had paused must stay paused")
        XCTAssertEqual([spotify.pauseCalls, spotify.playCalls], [0, 0], "and is not touched at all")
    }

    func testNothingPlayingNothingHappens() {
        let players = [FakeMediaPlayer("music", .paused), FakeMediaPlayer("spotify", .notRunning),
                       FakeMediaPlayer("other", .stopped)]
        let coordinator = MediaPauseCoordinator(players: players)
        coordinator.begin(generation: 1)
        coordinator.end(generation: 1)
        XCTAssertEqual(players.map { $0.pauseCalls + $0.playCalls }, [0, 0, 0])
    }

    // The second dictation starts before the first one's resume ran: the music
    // is paused once, stays paused through the first's late end, and comes back
    // after the second.
    func testASecondDictationBeforeTheFirstResumesNeitherDoublePausesNorLosesTheResume() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.begin(generation: 1)
        coordinator.begin(generation: 2)
        XCTAssertEqual(music.pauseCalls, 1, "already paused by us: not paused again")
        coordinator.end(generation: 1)
        XCTAssertEqual(music.playCalls, 0, "the first dictation's end must not resume mid-second-dictation")
        coordinator.end(generation: 2)
        XCTAssertEqual(music.playCalls, 1, "the resume survives the overlap")
        XCTAssertEqual(music.current, .playing)
    }

    func testAnEndWithNoMatchingStartDoesNothing() {
        let music = FakeMediaPlayer("music", .paused)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.end(generation: 7)
        XCTAssertEqual(music.playCalls, 0)
    }

    // The user pressed play (or stopped it) during the dictation: not ours to touch.
    func testAPlayerTheUserRestartedMeanwhileIsNotPlayedAgain() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.begin(generation: 1)
        music.current = .playing
        coordinator.end(generation: 1)
        XCTAssertEqual(music.playCalls, 0)
        let stopped = FakeMediaPlayer("stopped", .playing)
        let second = MediaPauseCoordinator(players: [stopped])
        second.begin(generation: 1)
        stopped.current = .stopped
        second.end(generation: 1)
        XCTAssertEqual(stopped.playCalls, 0, "a stopped player is not resumed")
    }

    func testTurnedOffTouchesNothing() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music], isEnabled: { false })
        coordinator.begin(generation: 1)
        coordinator.end(generation: 1)
        XCTAssertEqual(music.pauseCalls + music.playCalls, 0)
    }

    // Turning the setting off mid-dictation must still give the music back.
    func testTurningItOffMidDictationStillResumes() {
        var enabled = true
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music], isEnabled: { enabled })
        coordinator.begin(generation: 1)
        enabled = false
        coordinator.end(generation: 1)
        XCTAssertEqual(music.current, .playing)
    }

    func testTheDeniedNoticeIsOncePerLaunch() {
        let music = FakeMediaPlayer("music", .denied)
        let spotify = FakeMediaPlayer("spotify", .denied)
        let coordinator = MediaPauseCoordinator(players: [music, spotify])
        var notices = 0
        coordinator.onPermissionDenied = { notices += 1 }
        for generation in 1...3 {
            coordinator.begin(generation: generation)
            coordinator.end(generation: generation)
        }
        XCTAssertEqual(notices, 1, "one notice per launch, however many players and dictations")
        XCTAssertEqual(music.pauseCalls + spotify.pauseCalls, 0)
    }

    func testTheSettingDefaultsToOn() {
        let suite = "ox-say-media-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MediaPauseSetting.isEnabled(defaults))
        defaults.set(false, forKey: MediaPauseSetting.defaultsKey)
        XCTAssertFalse(MediaPauseSetting.isEnabled(defaults))
        defaults.set(true, forKey: MediaPauseSetting.defaultsKey)
        XCTAssertTrue(MediaPauseSetting.isEnabled(defaults))
    }
}

/// The journeys through the real DictationController: every way a recording
/// ends must give the music back.
final class MediaPauseJourneyTests: XCTestCase {
    private func rig(samples: Int, mode: HotkeyMode = .hold,
                     transcribe: @escaping ([Float]) async throws -> String = { _ in "hello" })
        -> (DictationController, FakeRecorder, FakeMediaPlayer, MediaPauseRunner) {
        let music = FakeMediaPlayer("music", .playing)
        let runner = MediaPauseRunner(coordinator: MediaPauseCoordinator(players: [music]))
        let recorder = FakeRecorder()
        recorder.samples = [Float](repeating: 0.1, count: samples)
        let controller = DictationController(recorder: recorder, output: FakeOutput(), mode: mode, transcribe: transcribe)
        // The AppDelegate's wiring: every state change goes to the runner.
        controller.onState = { runner.dictationStateChanged($0) }
        return (controller, recorder, music, runner)
    }

    @MainActor
    func testHoldPausesOnKeyDownAndResumesOnReleaseNotAfterTranscription() async {
        let (c, _, music, runner) = rig(samples: 16000) { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return "slow"
        }
        c.keyDown()
        runner.drain()
        XCTAssertEqual(music.current, .paused)
        c.keyUp()
        XCTAssertEqual(c.state, .transcribing)
        runner.drain()
        XCTAssertEqual(music.current, .playing, "the music returns at the release, not after the transcription")
        try? await Task.sleep(nanoseconds: 500_000_000)
        runner.drain()
        XCTAssertEqual(music.pauseCalls + music.playCalls, 2, "and the end of the transcription adds nothing")
    }

    // F2 — journey: a key tap (recording under minSeconds) goes recording ->
    // idle without ever transcribing. Mutation: in
    // MediaPauseRunner.dictationStateChanged make the end branch
    // `guard active, state == .transcribing` (ignore .idle) -> the tap, esc,
    // start-error and quit tests stay paused (RED). The AppDelegate half of F2
    // is testTheAppDelegateForwardsEveryStateToTheRunner below.
    @MainActor
    func testATapResumes() {
        let (c, _, music, runner) = rig(samples: 1600)
        c.keyDown(); runner.drain()
        XCTAssertEqual(music.current, .paused)
        c.keyUp(); runner.drain()
        XCTAssertEqual(music.current, .playing)
    }

    @MainActor
    func testEscCancelResumes() {
        let (c, _, music, runner) = rig(samples: 16000)
        c.keyDown(); runner.drain()
        c.cancel(); runner.drain()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(music.current, .playing)
    }

    @MainActor
    func testARecorderThatFailsToStartResumes() {
        let (c, recorder, music, runner) = rig(samples: 16000)
        recorder.startError = NSError(domain: "mic", code: 1)
        c.keyDown(); runner.drain()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(music.current, .playing)
    }

    @MainActor
    func testTheRecordingCapResumes() {
        let (c, _, music, runner) = rig(samples: 16000)
        c.keyDown(); runner.drain()
        c.finishRecording(); runner.drain()
        XCTAssertEqual(music.current, .playing)
    }

    @MainActor
    func testQuittingMidDictationResumes() {
        let (c, _, music, runner) = rig(samples: 16000)
        c.keyDown(); runner.drain()
        runner.dictationStateChanged(.idle) // applicationWillTerminate
        runner.drain()
        XCTAssertEqual(music.current, .playing)
    }

    // The hotkey must not wait for a player: a player that takes a second to
    // answer leaves keyDown unblocked. Mutation: queue.async -> queue.sync in
    // MediaPauseRunner.dictationStateChanged -> RED (the call waits ~1 s).
    func testAStateChangeNeverWaitsForAPlayer() {
        let slow = FakeMediaPlayer("music", .playing)
        slow.gate = DispatchSemaphore(value: 0)
        let runner = MediaPauseRunner(coordinator: MediaPauseCoordinator(players: [slow]))
        let started = Date()
        runner.dictationStateChanged(.recording)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "keyDown must return before the player answers")
        slow.gate?.signal()
        runner.drain()
    }

    // Wiring guard (the AppDelegate is AppKit and cannot run here): the
    // controller's state callback must hand EVERY state to the runner. A
    // callback that forwards only .recording would pause on the key down and
    // never resume on a tap, a cancel or a failure.
    func testTheAppDelegateForwardsEveryStateToTheRunner() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)
        let wiring = lines.filter { $0.contains("controller.onState =") }
        XCTAssertEqual(wiring.count, 1, "the controller's state callback is assigned in exactly one place")
        let line = wiring.first ?? ""
        XCTAssertTrue(line.contains("mediaPause.dictationStateChanged(state)"),
                      "controller.onState does not hand the state to the media runner")
        for conditional in [" if ", "guard ", "switch ", "case ", "where "] {
            XCTAssertFalse(line.contains(conditional),
                           "controller.onState filters what the media runner sees (\(conditional.trimmingCharacters(in: .whitespaces))): the resume would be skipped for some endings")
        }
        XCTAssertTrue(source.contains("mediaPause.drain()"),
                      "applicationWillTerminate must wait for the resume, or quitting mid-dictation leaves the music paused")
    }
}

/// Records every script handed to it; answers with a canned outcome.
final class FakeScriptRunner: AppleScriptRunner {
    var outcome: ScriptOutcome = .value("playing")
    private(set) var scripts: [String] = []
    func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome {
        scripts.append(source)
        return outcome
    }
}

final class ScriptedMediaPlayerTests: XCTestCase {
    private func player(running: Bool, runner: FakeScriptRunner, log: @escaping (String) -> Void = { _ in })
        -> ScriptedMediaPlayer {
        ScriptedMediaPlayer(bundleID: ScriptedMediaPlayer.musicBundleID, isRunning: { _ in running },
                            runner: runner, log: log)
    }

    // F3 — journey: Spotify is not running. Nothing may be sent to it: an
    // Apple Event to a closed app launches it. Mutation: delete
    // `guard isRunning(bundleID) else { return .notRunning }` in
    // ScriptedMediaPlayer.state (and the guard in `command`) -> RED.
    func testANonRunningAppIsNeverAddressed() {
        let runner = FakeScriptRunner()
        let closed = player(running: false, runner: runner)
        XCTAssertEqual(closed.state(), .notRunning)
        closed.pause()
        closed.play()
        XCTAssertEqual(runner.scripts, [], "an Apple Event to a closed app would launch it")
    }

    func testARunningAppIsAskedAndAnswersMapToStates() {
        let runner = FakeScriptRunner()
        let music = player(running: true, runner: runner)
        for (answer, expected) in [("playing", MediaPlaybackState.playing), ("paused", .paused),
                                   ("stopped", .stopped), ("notRunning", .notRunning), ("???", .unavailable)] {
            runner.outcome = .value(answer)
            XCTAssertEqual(music.state(), expected, "answer \(answer)")
        }
        runner.outcome = .denied
        XCTAssertEqual(music.state(), .denied)
        runner.outcome = .timedOut
        XCTAssertEqual(music.state(), .unavailable)
        runner.outcome = .failed(-600)
        XCTAssertEqual(music.state(), .unavailable)
    }

    func testPauseAndPlaySendTheRightVerbs() {
        let runner = FakeScriptRunner()
        let music = player(running: true, runner: runner)
        music.pause()
        music.play()
        XCTAssertEqual(runner.scripts.count, 2)
        XCTAssertTrue(runner.scripts[0].contains("\npause\n") || runner.scripts[0].contains(" pause\n"))
        XCTAssertTrue(runner.scripts[1].contains(" play\n"))
        XCTAssertTrue(runner.scripts.allSatisfy { $0.contains("application id \"com.apple.Music\"") })
    }

    // The app may quit between the running check and the script: `tell
    // application` would relaunch it, so the script tests `is running` itself,
    // before the tell. Mutation: drop that `if` from ScriptedMediaPlayer.script -> RED.
    func testEveryScriptChecksTheAppIsRunningBeforeTheTell() {
        let runner = FakeScriptRunner()
        let music = player(running: true, runner: runner)
        _ = music.state(); music.pause(); music.play()
        XCTAssertEqual(runner.scripts.count, 3)
        for script in runner.scripts {
            guard let running = script.range(of: "is running then"), let tell = script.range(of: "tell application id") else {
                XCTFail("script lacks the running check or the tell:\n\(script)"); continue
            }
            XCTAssertLessThan(running.lowerBound, tell.lowerBound)
            XCTAssertTrue(script.contains("with timeout of 1 second"), "a hung player must not hold the worker for minutes")
        }
    }

    func testFailuresAreLoggedWithoutUserContent() {
        let runner = FakeScriptRunner()
        var lines: [String] = []
        let music = player(running: true, runner: runner) { lines.append($0) }
        runner.outcome = .denied; _ = music.state()
        runner.outcome = .timedOut; music.pause()
        runner.outcome = .failed(-1728); music.play()
        XCTAssertEqual(lines, ["com.apple.Music state: automation denied (-1743)",
                               "com.apple.Music pause: timed out",
                               "com.apple.Music play: failed code=-1728"])
    }
}

/// The runner's deadline and the error-code mapping. The real NSAppleScript is
/// not run here: loading it into the test process wedges the shim's main
/// executor, so it is exercised once by hand instead (see the PR notes).
final class QueuedScriptRunnerTests: XCTestCase {
    func testReturnsTheScriptsValue() {
        let runner = QueuedScriptRunner { _ in .value("playing") }
        XCTAssertEqual(runner.run("x", timeout: 5), .value("playing"))
    }

    func testErrorMinus1743IsDeniedAndOthersKeepTheirCode() {
        XCTAssertEqual(QueuedScriptRunner.outcome(errorNumber: -1743), .denied)
        XCTAssertEqual(QueuedScriptRunner.outcome(errorNumber: -1728), .failed(-1728))
        XCTAssertEqual(QueuedScriptRunner.outcome(errorNumber: 0), .failed(0))
    }

    func testASlowScriptTimesOutForTheCaller() {
        let runner = QueuedScriptRunner { _ in Thread.sleep(forTimeInterval: 1); return .value("late") }
        let started = Date()
        XCTAssertEqual(runner.run("x", timeout: 0.2), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "the caller is released at the timeout")
    }
}
