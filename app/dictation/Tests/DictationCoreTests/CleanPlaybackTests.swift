import XCTest
@testable import DictationCore

final class CleanPlaybackTests: XCTestCase {
    /// Switching sides keeps the position and whether it plays: the same word is heard before and after.
    /// Mutation: CleanPlayback.choose resets `position` to 0 -> RED.
    func testSwitchingSidesKeepsThePositionAndPlayState() {
        var p = CleanPlayback(side: .cleaned, isPlaying: true, position: 12.5, duration: 60)
        XCTAssertEqual(p.choose(.original), .load(side: .original, position: 12.5, play: true))
        XCTAssertEqual(p.side, .original)
        XCTAssertNil(p.choose(.original), "the side already chosen does nothing")
        p.isPlaying = false
        XCTAssertEqual(p.choose(.cleaned), .load(side: .cleaned, position: 12.5, play: false))
    }

    func testTheFirstPressLoadsTheChosenSideThenItTogglesInPlace() {
        var p = CleanPlayback()
        XCTAssertEqual(p.side, .cleaned, "the result is heard first")
        XCTAssertEqual(p.toggle(loaded: false), .load(side: .cleaned, position: 0, play: true))
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(p.toggle(loaded: true), .pause)
        XCTAssertEqual(p.toggle(loaded: true), .play)
    }

    func testSeekClampsToTheFileAndEndRewinds() {
        var p = CleanPlayback(isPlaying: true, position: 5, duration: 30)
        XCTAssertEqual(p.seek(to: 99), .seek(30))
        XCTAssertEqual(p.seek(to: -4), .seek(0))
        p.tick(position: 7.25, duration: 31)
        XCTAssertEqual(p.position, 7.25)
        XCTAssertEqual(p.duration, 31)
        p.ended()
        XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.position, 0)
    }
}
