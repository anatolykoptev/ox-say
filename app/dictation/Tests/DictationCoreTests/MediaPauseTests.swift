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
    private(set) var waits: [MediaWait] = []
    /// Answers handed out before `current`, one per `state` call: a player
    /// that times out, then recovers.
    var answers: [MediaPlaybackState] = []
    /// When set, `state` waits on it (up to a second) like a player that
    /// answers slowly.
    var gate: DispatchSemaphore?

    init(_ identifier: String, _ state: MediaPlaybackState) {
        self.identifier = identifier
        current = state
    }

    /// Outcomes handed out by `play`, one per call: a play that the player
    /// did not take the first time.
    var playOutcomes: [ScriptOutcome] = []

    func state(wait: MediaWait) -> MediaPlaybackState {
        waits.append(wait)
        _ = gate?.wait(timeout: .now() + 1)
        return answers.isEmpty ? current : answers.removeFirst()
    }
    func pause() { pauseCalls += 1; current = .paused }
    func play() -> ScriptOutcome {
        playCalls += 1
        current = .playing
        return playOutcomes.isEmpty ? .value("ok") : playOutcomes.removeFirst()
    }
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

    // Dictations follow each other on one queue, so an end always runs before
    // the next begin: each pauses and resumes in turn.
    func testConsecutiveDictationsEachPauseAndResume() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.begin(generation: 1)
        coordinator.end(generation: 1)
        coordinator.begin(generation: 2)
        XCTAssertEqual(music.current, .paused)
        coordinator.end(generation: 2)
        XCTAssertEqual(music.current, .playing)
        XCTAssertEqual([music.pauseCalls, music.playCalls], [2, 2])
    }

    // A player already paused at the start is the user's: never taken over.
    func testAPlayerPausedAtTheStartIsNotOurs() {
        let music = FakeMediaPlayer("music", .paused)
        let coordinator = MediaPauseCoordinator(players: [music])
        coordinator.begin(generation: 1)
        coordinator.end(generation: 1)
        XCTAssertEqual(music.pauseCalls + music.playCalls, 0)
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

    // F4 (unit) — the pause answered late, so at the end the player's state
    // call timed out: the music is still ours to give back. Mutation: in
    // MediaPauseCoordinator.resume replace the whole body with
    // `if player.state(wait: .quick) == .paused { player.play() }` -> RED, and
    // the sibling testASlowPauseStillResumesOnRelease goes RED with it.
    func testAPlayerThatDoesNotAnswerAtTheEndIsPlayedAnyway() {
        let music = FakeMediaPlayer("music", .playing)
        let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0)
        coordinator.begin(generation: 1)
        music.answers = [.timedOut, .timedOut]
        coordinator.end(generation: 1)
        XCTAssertEqual(music.playCalls, 1, "an unknown state must not leave the music paused")
    }

    func testTheResumeAsksAgainOnceAfterATimeout() {
        let music = FakeMediaPlayer("music", .playing)
        var errors: [String] = []
        let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0, logError: { errors.append($0) })
        coordinator.begin(generation: 1)
        music.answers = [.timedOut]
        coordinator.end(generation: 1)
        XCTAssertEqual(music.waits, [.quick, .confirming, .confirming], "the resume waits long, and asks twice")
        XCTAssertEqual(music.playCalls, 1)
        XCTAssertEqual(errors, [], "answered on the retry: nothing to report")
        // The retry shows the user took over: left be.
        let other = FakeMediaPlayer("other", .playing)
        let second = MediaPauseCoordinator(players: [other], retryDelay: 0, logError: { errors.append($0) })
        second.begin(generation: 1)
        other.answers = [.unavailable, .playing]
        second.end(generation: 1)
        XCTAssertEqual(other.playCalls, 0)
        XCTAssertEqual(errors, [])
    }

    func testAResumeThatCannotBeConfirmedIsLoggedWithoutContent() {
        let music = FakeMediaPlayer("com.apple.Music", .playing)
        var errors: [String] = []
        let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0, logError: { errors.append($0) })
        coordinator.begin(generation: 1)
        music.answers = [.timedOut, .unavailable]
        coordinator.end(generation: 1)
        XCTAssertEqual(errors, ["com.apple.Music resume unconfirmed (unavailable): playing anyway"])
        XCTAssertEqual(music.playCalls, 1)
    }

    // F5 (#195.1) — a `play` the player did not take gets one retry, and only
    // a play that fails twice is an error line. Mutation: in
    // MediaPauseCoordinator.play drop the retry -> playCalls is 1 and the
    // error fires on the first failure (both halves go RED).
    func testAPlayThatFailsOnceIsRetried() {
        let music = FakeMediaPlayer("com.apple.Music", .playing)
        var errors: [String] = []
        let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0, logError: { errors.append($0) })
        coordinator.begin(generation: 1)
        music.answers = [.paused]
        music.playOutcomes = [.timedOut, .value("ok")]
        coordinator.end(generation: 1)
        XCTAssertEqual(music.playCalls, 2, "the failed play is asked once more")
        XCTAssertEqual(music.current, .playing)
        XCTAssertEqual(errors, [], "a recovered play is not an error")
    }

    func testAPlayThatStillFailsIsAnErrorWithoutContent() {
        let music = FakeMediaPlayer("com.apple.Music", .playing)
        var errors: [String] = []
        let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0, logError: { errors.append($0) })
        coordinator.begin(generation: 1)
        music.answers = [.paused]
        music.playOutcomes = [.timedOut, .failed(-1728)]
        coordinator.end(generation: 1)
        XCTAssertEqual(music.playCalls, 2, "the retry ran")
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("com.apple.Music play did not take") ?? false, "\(errors)")
    }

    func testAPlayerTheUserTookOverIsLeftBeAtTheEnd() {
        for taken in [MediaPlaybackState.playing, .stopped, .notRunning] {
            let music = FakeMediaPlayer("music", .playing)
            let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0)
            coordinator.begin(generation: 1)
            music.current = taken
            coordinator.end(generation: 1)
            XCTAssertEqual(music.playCalls, 0, "\(taken) at the end is not ours to play")
        }
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

    // #195.4 — a player that does not answer the start is not known to be
    // playing: it is not paused, so nothing of it is ours to play at the end.
    // Mutation: in MediaPauseCoordinator.begin let `.timedOut, .unavailable`
    // fall into the `.playing` case -> pauseCalls is 1 and the end plays (RED).
    func testAPlayerThatDoesNotAnswerTheStartIsNeitherPausedNorPlayed() {
        for unknown in [MediaPlaybackState.timedOut, .unavailable] {
            let music = FakeMediaPlayer("music", .playing)
            music.answers = [unknown]
            var errors: [String] = []
            let coordinator = MediaPauseCoordinator(players: [music], retryDelay: 0, logError: { errors.append($0) })
            coordinator.begin(generation: 1)
            coordinator.end(generation: 1)
            XCTAssertEqual(music.pauseCalls, 0, "\(unknown) at the start: no pause")
            XCTAssertEqual(music.playCalls, 0, "\(unknown) at the start: no later play")
            XCTAssertEqual(music.waits, [.quick], "and the end asks nobody")
            XCTAssertEqual(errors, [])
        }
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

}

/// The setting lives in `SoundWhileDictatingSetting` now: the old on/off maps
/// to Pause Music / Don't Touch — tested in SoundWhileDictatingSettingTests.

/// The journeys through the real DictationController: every way a recording
/// ends must give the music back.
final class MediaPauseJourneyTests: XCTestCase {
    private func rig(samples: Int, mode: HotkeyMode = .hold,
                     transcribe: @escaping ([Float]) async throws -> String = { _ in "hello" })
        -> (DictationController, FakeRecorder, FakeMediaPlayer, SoundWhileDictatingRunner) {
        let music = FakeMediaPlayer("music", .playing)
        let runner = SoundWhileDictatingRunner(pause: MediaPauseCoordinator(players: [music]),
                                               mode: { .pauseMusic })
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
    // SoundWhileDictatingRunner.dictationStateChanged make the end branch
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
    // SoundWhileDictatingRunner.dictationStateChanged -> RED (the call waits ~1 s).
    func testAStateChangeNeverWaitsForAPlayer() {
        let slow = FakeMediaPlayer("music", .playing)
        slow.gate = DispatchSemaphore(value: 0)
        let runner = SoundWhileDictatingRunner(pause: MediaPauseCoordinator(players: [slow]),
                                               mode: { .pauseMusic })
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
        XCTAssertTrue(line.contains("soundWhileDictating.dictationStateChanged(state)"),
                      "controller.onState does not hand the state to the sound runner")
        for conditional in [" if ", "guard ", "switch ", "case ", "where "] {
            XCTAssertFalse(line.contains(conditional),
                           "controller.onState filters what the sound runner sees (\(conditional.trimmingCharacters(in: .whitespaces))): the resume would be skipped for some endings")
        }
        let terminate = try applicationWillTerminateCode()
        XCTAssertTrue(terminate.contains("soundWhileDictating.drain(timeout:"),
                      "applicationWillTerminate must wait for the resume — bounded, or a hang holds the quit open")
    }
}

/// Records every script handed to it; answers with a canned outcome.
final class FakeScriptRunner: AppleScriptRunner {
    var outcome: ScriptOutcome = .value("playing")
    private(set) var scripts: [String] = []
    private(set) var timeouts: [TimeInterval] = []
    func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome {
        scripts.append(source)
        timeouts.append(timeout)
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
        XCTAssertEqual(closed.state(wait: .quick), .notRunning)
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
            XCTAssertEqual(music.state(wait: .quick), expected, "answer \(answer)")
        }
        runner.outcome = .denied
        XCTAssertEqual(music.state(wait: .quick), .denied)
        runner.outcome = .timedOut
        XCTAssertEqual(music.state(wait: .quick), .timedOut, "unknown, and told apart from an error")
        runner.outcome = .failed(-600)
        XCTAssertEqual(music.state(wait: .quick), .unavailable)
    }

    // The giving-back calls outwait the script's own 1 s limit; the pause at
    // the start of a dictation does not hold the recording back.
    func testTheResumeWaitsLongerThanTheScriptsOwnTimeout() {
        let runner = FakeScriptRunner()
        let music = player(running: true, runner: runner)
        _ = music.state(wait: .quick); music.pause(); _ = music.state(wait: .confirming); music.play()
        XCTAssertEqual(runner.timeouts, [0.3, 0.3, 1.5, 1.5])
        XCTAssertGreaterThan(ScriptedMediaPlayer.confirmTimeout, 1, "must exceed `with timeout of 1 second`")
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
        _ = music.state(wait: .quick); music.pause(); music.play()
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
        runner.outcome = .denied; _ = music.state(wait: .quick)
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


/// A pretend Music and Spotify behind the real players, workers and wiring:
/// scripts are answered from this table, nothing reaches a real player.
final class FakeScriptWorld {
    private let lock = NSLock()
    private var states: [String: String]
    private var log: [(bundle: String, verb: String)] = []
    /// Bundle → seconds every script of it takes before answering.
    var hang: [String: TimeInterval] = [:]
    /// Bundle → seconds a `pause` takes (the player pauses at once, replies late).
    var slowPause: [String: TimeInterval] = [:]
    var denied: Set<String> = []
    var running: Set<String>

    init(_ states: [String: String]) {
        self.states = states
        running = Set(states.keys)
    }

    func state(_ bundle: String) -> String { lock.withLock { states[bundle] ?? "?" } }
    func verbs(_ bundle: String) -> [String] { lock.withLock { log.filter { $0.bundle == bundle }.map(\.verb) } }
    var touched: [String] { lock.withLock { log.map(\.bundle) } }

    func isRunning(_ bundle: String) -> Bool { lock.withLock { running.contains(bundle) } }

    func execute(_ source: String) -> ScriptOutcome {
        let bundle = [ScriptedMediaPlayer.musicBundleID, ScriptedMediaPlayer.spotifyBundleID]
            .first { source.contains("application id \"\($0)\"") } ?? "?"
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let verb = lines.contains("return player state as text") ? "state"
            : lines.contains("pause") ? "pause" : lines.contains("play") ? "play" : "?"
        let (delay, deny) = lock.withLock { () -> (TimeInterval, Bool) in
            log.append((bundle, verb))
            var delay = hang[bundle] ?? 0
            if verb == "pause" { delay = max(delay, slowPause[bundle] ?? 0) }
            if verb == "pause" { states[bundle] = "paused" }
            if verb == "play" { states[bundle] = "playing" }
            return (delay, denied.contains(bundle))
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if deny { return .denied }
        if hang[bundle] != nil { return .failed(-1712) }
        return .value(verb == "state" ? state(bundle) : "ok")
    }
}

/// SoundWhileDictatingWiring is what the app runs: the players, a worker
/// each, the mode the menu stored, the duck, the denied callback. The
/// AppDelegate and SoundWhileDictatingSystem only hand it the process list,
/// the real script executor and the real volume.
final class SoundWhileDictatingWiringTests: XCTestCase {
    private let music = ScriptedMediaPlayer.musicBundleID
    private let spotify = ScriptedMediaPlayer.spotifyBundleID

    /// A private suite; the caller removes it when it set a value in it.
    private func defaults(_ name: String = "ox-say-media-wiring-\(UUID().uuidString)",
                          mode: SoundWhileDictating? = nil) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        if let mode { SoundWhileDictatingSetting.choose(mode, in: defaults) }
        return defaults
    }

    private func runner(_ world: FakeScriptWorld, defaults: UserDefaults? = nil,
                        volume: SystemVolume? = nil,
                        onPermissionDenied: @escaping () -> Void = {},
                        logError: @escaping (String) -> Void = { _ in }) -> SoundWhileDictatingRunner {
        SoundWhileDictatingWiring.makeRunner(isRunning: world.isRunning, execute: world.execute,
                                             volume: volume,
                                             defaults: defaults ?? self.defaults(mode: .pauseMusic), onPermissionDenied: onPermissionDenied,
                                             logError: logError)
    }

    // Mutation: in SoundWhileDictatingWiring.bundleIDs drop Spotify -> RED.
    func testMusicAndSpotifyAreBothPausedAndResumed() {
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        let r = runner(world)
        r.dictationStateChanged(.recording); r.drain()
        XCTAssertEqual([world.state(music), world.state(spotify)], ["paused", "paused"])
        r.dictationStateChanged(.transcribing); r.drain()
        XCTAssertEqual([world.state(music), world.state(spotify)], ["playing", "playing"])
    }

    // The menu pick reaches the runner: Pause Music pauses the players and
    // leaves the volume; Don't Touch sends no Apple Event at all and never
    // touches the volume. Mutation: in SoundWhileDictatingWiring.makeRunner
    // replace the `mode:` closure with `{ .pauseMusic }` -> the Don't Touch
    // half goes RED.
    func testTheModeOnPausesAndDontTouchTouchesNothing() {
        let suites = ["ox-say-media-on-\(UUID().uuidString)", "ox-say-media-off-\(UUID().uuidString)"]
        defer { suites.forEach { UserDefaults(suiteName: $0)!.removePersistentDomain(forName: $0) } }
        let on = FakeScriptWorld([music: "playing"])
        let rOn = runner(on, defaults: defaults(suites[0], mode: .pauseMusic))
        rOn.dictationStateChanged(.recording); rOn.drain()
        XCTAssertEqual(on.state(music), "paused")
        rOn.dictationStateChanged(.idle); rOn.drain()

        let off = FakeScriptWorld([music: "playing", spotify: "playing"])
        let fakeVolume = FakeSystemVolume()
        let rOff = runner(off, defaults: defaults(suites[1], mode: .dontTouch), volume: fakeVolume)
        rOff.dictationStateChanged(.recording); rOff.drain()
        rOff.dictationStateChanged(.idle); rOff.drain()
        XCTAssertEqual(off.touched, [], "Don't Touch: no Apple Event at all")
        XCTAssertEqual(fakeVolume.writes, [], "and no volume write either")
    }

    // Lower All Sound through the real wiring: the players get no Apple
    // Event, the volume takes the whole journey.
    func testLowerAllSoundDucksAndRestoresWithoutScripts() {
        let suite = "ox-say-media-duck-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        let fakeVolume = FakeSystemVolume()
        let r = runner(world, defaults: defaults(suite, mode: .lowerAllSound), volume: fakeVolume)
        r.dictationStateChanged(.recording); r.drain()
        XCTAssertEqual(fakeVolume.level, 0.8 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001)
        r.dictationStateChanged(.idle); r.drain()
        XCTAssertEqual(fakeVolume.level, 0.8, accuracy: 0.0001)
        XCTAssertEqual(world.touched, [], "the duck path sends no Apple Events")
    }

    // Lower All Sound on an output that cannot be lowered (HDMI, a USB DAC,
    // a Multi-Output device) pauses the players instead and resumes them on
    // release. Mutation: in SoundWhileDictatingRunner.dictationStateChanged
    // drop the `pause.begin(generation: g)` fallback -> RED.
    func testLowerAllSoundOnAnUnsettableOutputFallsBackToPausing() {
        let suite = "ox-say-media-fallback-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        let fakeVolume = FakeSystemVolume()
        fakeVolume.settable = false
        let r = runner(world, defaults: defaults(suite, mode: .lowerAllSound), volume: fakeVolume)
        r.dictationStateChanged(.recording); r.drain()
        XCTAssertEqual([world.state(music), world.state(spotify)], ["paused", "paused"])
        XCTAssertEqual(fakeVolume.writes, [])
        r.dictationStateChanged(.transcribing); r.drain()
        XCTAssertEqual([world.state(music), world.state(spotify)], ["playing", "playing"])
    }

    func testLowerAllSoundWithoutAnyVolumeAlsoFallsBackToPausing() {
        let suite = "ox-say-media-novolume-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let world = FakeScriptWorld([music: "playing"])
        let r = runner(world, defaults: defaults(suite, mode: .lowerAllSound), volume: nil)
        r.dictationStateChanged(.recording); r.drain()
        XCTAssertEqual(world.state(music), "paused")
        r.dictationStateChanged(.idle); r.drain()
        XCTAssertEqual(world.state(music), "playing")
    }

    // The crash path through the real wiring and the real defaults store (in
    // a private suite): the first runner ducks and is never ended; a second
    // one on the same defaults gives the level back at launch.
    func testAKilledDuckIsRestoredByTheNextLaunch() {
        let suite = "ox-say-media-crash-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let d = defaults(suite, mode: .lowerAllSound)
        let fakeVolume = FakeSystemVolume()
        let first = runner(FakeScriptWorld([:]), defaults: d, volume: fakeVolume)
        first.dictationStateChanged(.recording); first.drain()
        XCTAssertEqual(fakeVolume.level, 0.8 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001)
        // SIGKILL: no `.idle` ever reaches `first`. The next launch:
        let second = runner(FakeScriptWorld([:]), defaults: d, volume: fakeVolume)
        second.recoverInterruptedDuck(); second.drain()
        XCTAssertEqual(fakeVolume.level, 0.8, accuracy: 0.0001)
    }

    // Mutation: delete `coordinator.onPermissionDenied = onPermissionDenied`
    // in SoundWhileDictatingWiring.makeRunner -> RED.
    func testADeniedAutomationReachesTheNoticeOnce() {
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        world.denied = [music, spotify]
        var notices = 0
        let r = runner(world, onPermissionDenied: { notices += 1 })
        for _ in 1...2 { r.dictationStateChanged(.recording); r.dictationStateChanged(.idle) }
        r.drain()
        XCTAssertEqual(notices, 1)
    }

    func testAPlayerThatIsNotRunningIsNeverAddressed() {
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        world.running = [music]
        let r = runner(world)
        r.dictationStateChanged(.recording); r.dictationStateChanged(.idle); r.drain()
        XCTAssertFalse(world.touched.isEmpty)
        XCTAssertEqual(world.verbs(spotify), [], "an Apple Event to a closed Spotify would launch it")
    }

    // F5 — journey: Music hangs (every call takes 0.9 s, beyond the quick
    // wait) while Spotify plays. Spotify is still paused promptly and given
    // back. Mutation: in SoundWhileDictatingWiring.makeRunner build ONE QueuedScriptRunner
    // before `bundleIDs.map` and pass it to every player -> Spotify's state
    // call queues behind Music's, times out, and Spotify is never paused (RED).
    func testAHungMusicDoesNotDelayOrBlockSpotify() {
        let world = FakeScriptWorld([music: "playing", spotify: "playing"])
        world.hang[music] = 0.9
        let r = runner(world)
        let started = Date()
        r.dictationStateChanged(.recording); r.drain()
        XCTAssertEqual(world.state(spotify), "paused", "Spotify must not wait for a hung Music")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        r.dictationStateChanged(.transcribing); r.drain()
        XCTAssertEqual(world.state(spotify), "playing")
    }

    // F4 — journey: Music takes 0.9 s to answer its pause, past the quick wait.
    // The release finds the music paused and gives it back, however slowly the
    // player answers. Mutation: in MediaPauseCoordinator.resume replace the body
    // with `if player.state(wait: .quick) == .paused { player.play() }` (the
    // shape before this fix) -> the state call times out behind the pause, the
    // play is skipped and the music stays paused (RED).
    func testASlowPauseStillResumesOnRelease() {
        let world = FakeScriptWorld([music: "playing"])
        world.slowPause[music] = 0.9
        let r = runner(world)
        r.dictationStateChanged(.recording)
        r.dictationStateChanged(.transcribing)
        r.drain()
        XCTAssertEqual(world.state(music), "playing", "music left paused after a slow pause")
        XCTAssertEqual(world.verbs(music).filter { $0 == "play" }.count, 1)
    }
}

/// The mode-aware glue checks live in SoundWhileDictatingAppGlueTests: system
/// side, mode pass-through, and the bounded drain inside
/// applicationWillTerminate.
