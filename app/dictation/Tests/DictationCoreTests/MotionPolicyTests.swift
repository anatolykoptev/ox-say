import XCTest
@testable import DictationCore

/// Reduce Motion turns every interface animation into a no-op. The window's animated changes go
/// through `MotionPolicy.animationSeconds`, so the setting is honoured in one place.
/// Mutation: `reduceMotion ? 0 : nominal` -> `nominal` -> RED.
final class MotionPolicyTests: XCTestCase {
    func testReducedMotionMeansNoAnimation() {
        XCTAssertEqual(MotionPolicy.animationSeconds(0.25, reduceMotion: true), 0)
        XCTAssertEqual(MotionPolicy.animationSeconds(0.25, reduceMotion: false), 0.25)
    }
}
