import XCTest
@testable import DictationCore

/// #452 — the one Find command (⌘F): where it goes depends on what is on screen.
final class FindTargetTests: XCTestCase {
    /// The transcript's own bar wins while a transcript is on screen, even with the list's field up too.
    /// Mutation: FindTarget.decide, check `meetingsSearchOnScreen` before `transcriptOnScreen` -> RED.
    func testTheTranscriptFindWinsWhileItIsOnScreen() {
        XCTAssertEqual(FindTarget.decide(transcriptOnScreen: true, meetingsSearchOnScreen: true), .transcript)
        XCTAssertEqual(FindTarget.decide(transcriptOnScreen: true, meetingsSearchOnScreen: false), .transcript)
    }

    /// The meetings search field is the fallback — and with neither on screen the command goes nowhere.
    /// Mutation: FindTarget.decide, return `.meetingsSearch` unconditionally -> RED.
    func testTheMeetingsSearchIsTheFallback() {
        XCTAssertEqual(FindTarget.decide(transcriptOnScreen: false, meetingsSearchOnScreen: true), .meetingsSearch)
        XCTAssertNil(FindTarget.decide(transcriptOnScreen: false, meetingsSearchOnScreen: false))
    }
}
