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

    func testTheEndOfAClipReleasesTheHandshakeAndAFailedStartResets() {
        var a = ClipAudio()
        _ = a.start(recordingRunning: false)
        XCTAssertEqual(a.finished(), [.handshakeMayRun])
        XCTAssertEqual(a.sound, .stopped)
        _ = a.start(recordingRunning: false)
        a.startFailed()
        XCTAssertEqual(a.sound, .stopped)
        XCTAssertFalse(a.busy)
    }
}
