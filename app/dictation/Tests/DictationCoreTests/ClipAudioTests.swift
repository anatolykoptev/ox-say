import XCTest
@testable import DictationCore

final class ClipAudioTests: XCTestCase {
    /// A clip that sounds holds the version handshake (`appWork.speaking`); every way it stops releases it.
    /// Mutation: ClipAudio.stop, drop `.handshakeMayRun` -> RED.
    func testStoppingAClipThatSoundsLetsTheHandshakeRun() {
        var a = ClipAudio()
        XCTAssertEqual(a.start(recordingRunning: false), [.stopOtherAudio, .start])
        XCTAssertEqual(a.stop(), [.halt, .handshakeMayRun])
        XCTAssertEqual(a.sound, .stopped)
    }

    func testStoppingWhatDoesNotSoundHoldsNothing() {
        var a = ClipAudio()
        XCTAssertEqual(a.stop(), [], "nothing was playing")
        _ = a.start(recordingRunning: false)
        _ = a.playPause(recordingRunning: false)   // paused: not busy, the pause already released the handshake
        XCTAssertEqual(a.stop(), [.halt])
    }

    func testPauseReleasesAndResumeStopsOtherAudioFirst() {
        var a = ClipAudio()
        _ = a.start(recordingRunning: false)
        XCTAssertEqual(a.playPause(recordingRunning: false), [.pause, .handshakeMayRun])
        XCTAssertEqual(a.sound, .paused)
        XCTAssertEqual(a.playPause(recordingRunning: false), [.stopOtherAudio, .resume])
        XCTAssertEqual(a.sound, .playing)
    }

    /// A recording captures the output: a clip never starts into one, and a paused clip does not resume into one.
    /// Mutation: ClipAudio.start, delete the `recordingRunning` guard -> RED.
    func testAClipNeverStartsOrResumesIntoARecording() {
        var a = ClipAudio()
        XCTAssertEqual(a.start(recordingRunning: true), [.blockedByRecording])
        XCTAssertEqual(a.sound, .stopped)
        _ = a.start(recordingRunning: false)
        _ = a.playPause(recordingRunning: false)
        XCTAssertEqual(a.playPause(recordingRunning: true), [.halt, .blockedByRecording])
        XCTAssertEqual(a.sound, .stopped)
        XCTAssertEqual(a.playPause(recordingRunning: true), [.blockedByRecording], "stopped -> start -> refused")
    }

    func testPlayingThenARecordingStartsStopsTheClipAndReleasesTheHandshake() {
        var a = ClipAudio()
        _ = a.start(recordingRunning: false)
        XCTAssertEqual(a.start(recordingRunning: true), [.halt, .handshakeMayRun, .blockedByRecording])
    }

    /// A tracked `.playing` that the player no longer backs (it stopped without `didFinish`) holds nothing.
    /// Mutation: ClipAudio.busy, drop `&& playerIsPlaying` -> RED.
    func testATrackedClipTheDevicePlayerNoLongerSoundsHoldsNothing() {
        var a = ClipAudio()
        _ = a.start(recordingRunning: false)
        XCTAssertTrue(a.busy(playerIsPlaying: true))
        XCTAssertFalse(a.busy(playerIsPlaying: false))
        XCTAssertFalse(ClipAudio().busy(playerIsPlaying: true), "a stopped clip never holds it")
    }

    func testTheEndOfAClipReleasesTheHandshakeAndAFailedStartResets() {
        var a = ClipAudio()
        _ = a.start(recordingRunning: false)
        XCTAssertEqual(a.finished(), [.handshakeMayRun])
        XCTAssertEqual(a.sound, .stopped)
        _ = a.start(recordingRunning: false)
        a.startFailed()
        XCTAssertEqual(a.sound, .stopped)
        XCTAssertFalse(a.busy(playerIsPlaying: true))
    }

    /// The waveform cursor timer follows the sound: it ticks only while the clip sounds, and never under Reduce Motion.
    /// A clip that ends on its own and the stop of one that already ended must both read "no ticks" (a timer left running
    /// wakes the app four times a second for the life of the process).
    func testTheCursorTicksOnlyWhileTheClipSounds() {
        var audio = ClipAudio()
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false), "nothing sounds yet")
        _ = audio.start(recordingRunning: false)
        XCTAssertTrue(audio.cursorTicks(reduceMotion: false))
        XCTAssertFalse(audio.cursorTicks(reduceMotion: true), "Reduce Motion: a static picture")
        _ = audio.playPause(recordingRunning: false)
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false), "paused")
        _ = audio.playPause(recordingRunning: false)
        XCTAssertTrue(audio.cursorTicks(reduceMotion: false), "resumed")
        _ = audio.finished()
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false), "the clip ended on its own")
        XCTAssertEqual(audio.stop(), [], "a stop of a clip that already ended has no effect to hang a timer stop on")
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false))
        _ = audio.start(recordingRunning: false)
        _ = audio.stop()
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false))
        _ = audio.start(recordingRunning: true)
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false), "blocked by a recording")
        _ = audio.start(recordingRunning: false)
        audio.startFailed()
        XCTAssertFalse(audio.cursorTicks(reduceMotion: false), "the player could not start")
    }
}
