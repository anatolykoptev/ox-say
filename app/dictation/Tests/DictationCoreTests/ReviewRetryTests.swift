import XCTest
@testable import DictationCore

/// A start the daemon refuses must not cost the person their editing session.
@MainActor
final class ReviewRetryTests: XCTestCase {
    private struct Refused: Error, Equatable { var why: String }

    func testCancellingTheReviewStartsNothing() async {
        var started = 0
        let result: String? = await ReviewRetry.run("draft", review: { _ in nil }, start: { _ in started += 1; return "job" }, failed: { _ in })
        XCTAssertNil(result)
        XCTAssertEqual(started, 0)
    }

    func testAStartThatWorksIsReturnedWithoutAMessage() async {
        var failures = 0
        let result = await ReviewRetry.run("draft", review: { $0 + " edited" }, start: { "job for " + $0 }, failed: { _ in failures += 1 })
        XCTAssertEqual(result, "job for draft edited")
        XCTAssertEqual(failures, 0)
    }

    func testARefusedStartReopensTheReviewWithWhatThePersonHad() async {
        var shown: [String] = []
        var said: [Refused] = []
        var attempts = 0
        let result = await ReviewRetry.run("original", review: { draft in
            shown.append(draft)
            return shown.count == 1 ? "original, edited by hand" : draft
        }, start: { draft in
            attempts += 1
            if attempts == 1 { throw Refused(why: "unknown directive [sic]") }
            return "job for " + draft
        }, failed: { said.append($0 as! Refused) })
        XCTAssertEqual(shown, ["original", "original, edited by hand"])
        XCTAssertEqual(said, [Refused(why: "unknown directive [sic]")])
        XCTAssertEqual(result, "job for original, edited by hand")
    }

    func testThePersonCanGiveUpAfterARefusal() async {
        var opened = 0
        let result: String? = await ReviewRetry.run("draft", review: { draft in
            opened += 1
            return opened == 1 ? draft : nil
        }, start: { _ in throw Refused(why: "no") }, failed: { _ in })
        XCTAssertNil(result)
        XCTAssertEqual(opened, 2)
    }
}
