import Foundation
import XCTest
@testable import DictationCore

final class AppWorkMeetingTests: XCTestCase {
    /// A relaunch or a daemon restart never fires under a recording.
    /// Mutation: VersionHandshake.AppWork.idle, drop `|| recordingMeeting` -> RED.
    func testRecordingAMeetingIsWork() {
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false).idle)
        XCTAssertFalse(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                                recordingMeeting: true).idle)
    }
}
