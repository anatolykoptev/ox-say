import Foundation
import XCTest
@testable import DictationCore

/// B5a: the empty meeting an aborted start leaves behind, the rename's re-read, the badge's place.
final class EmptyMeetingCleanupTests: XCTestCase {
    private struct Down: Error {}

    private final class Calls {
        var finish = 0, delete = 0
        var slept: [TimeInterval] = []
    }

    private func run(_ calls: Calls, finish: @escaping () async throws -> Void = {}, delete: @escaping () async throws -> Void) async -> EmptyMeetingCleanup.Outcome {
        await EmptyMeetingCleanup.discard(finish: { calls.finish += 1; try await finish() },
                                          delete: { calls.delete += 1; try await delete() },
                                          sleep: { calls.slept.append($0) })
    }

    /// The daemon refuses to delete a meeting that is still recording (409), so the meeting is finished first.
    /// Mutation: EmptyMeetingCleanup.discard, delete the `try await finish()` call -> RED.
    func testTheMeetingIsFinishedThenDeleted() async {
        let calls = Calls()
        let outcome = await run(calls, delete: {})
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(calls.finish, 1)
        XCTAssertEqual(calls.delete, 1)
    }

    /// 404 counts as gone (the retention sweep or the user got there first), also from the finish call.
    /// Mutation: EmptyMeetingCleanup.discard, treat 404 as a failure (`.left`) -> RED.
    func testNotFoundCountsAsGone() async {
        let calls = Calls()
        let outcome = await run(calls, delete: { throw StudioError.refused(status: 404, message: "no such meeting") })
        XCTAssertEqual(outcome, .gone)
        let calls2 = Calls()
        let outcome2 = await run(calls2, finish: { throw StudioError.refused(status: 404, message: "no such meeting") }, delete: {})
        XCTAssertEqual(outcome2, .gone)
        XCTAssertEqual(calls2.delete, 0, "nothing to delete")
    }

    /// The finished meeting is "queued" for a moment: 409 is waited out, a bounded number of times.
    /// Mutation: EmptyMeetingCleanup.discard, return `.left` on the first 409 -> RED.
    func testAProcessingMeetingIsRetriedThenDeleted() async {
        let calls = Calls()
        var n = 0
        let outcome = await run(calls, delete: { n += 1; if n < 3 { throw StudioError.refused(status: 409, message: "busy") } })
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(calls.delete, 3)
        XCTAssertEqual(calls.slept, [0.5, 1])
    }

    func testAMeetingThatStaysBusyIsLeftAndSaidNotLooped() async {
        let calls = Calls()
        let outcome = await run(calls, delete: { throw StudioError.refused(status: 409, message: "busy") })
        guard case .left = outcome else { return XCTFail("expected .left, got \(outcome)") }
        XCTAssertEqual(calls.delete, EmptyMeetingCleanup.waits.count + 1)
        XCTAssertEqual(calls.slept, EmptyMeetingCleanup.waits)
    }

    /// A daemon that is down is not retried here and is not "gone".
    func testAnUnreachableDaemonLeavesTheMeetingAndSaysWhy() async {
        let calls = Calls()
        let outcome = await run(calls, finish: { throw StudioError.daemonUnreachable }, delete: { throw StudioError.daemonUnreachable })
        guard case .left(let why) = outcome else { return XCTFail("expected .left, got \(outcome)") }
        XCTAssertTrue(why.contains("not running"), why)
        XCTAssertEqual(calls.delete, 1)
        XCTAssertTrue(calls.slept.isEmpty)
    }
}

/// #270: a rename must not hold the window's refresh up while the notes-folder copy is re-read.
final class StaleCopyRefreshTests: XCTestCase {
    private final class Log { var reads = 0; var slept: [TimeInterval] = [] }

    func testTheFirstReadThatWorksEndsIt() async {
        let log = Log()
        let got: String? = await StaleCopyRefresh.run(read: { log.reads += 1; return log.reads == 2 ? "info" : nil },
                                                      sleep: { log.slept.append($0) })
        XCTAssertEqual(got, "info")
        XCTAssertEqual(log.slept, [1])
    }

    /// No sleep after the last failed read: the old loop waited 3 s more before saying so.
    /// Mutation: StaleCopyRefresh.run, drop the `index < waits.count` check around the sleep -> RED.
    func testThreeFailedReadsGiveUpWithoutATrailingWait() async {
        let log = Log()
        let got: String? = await StaleCopyRefresh.run(read: { log.reads += 1; return nil }, sleep: { log.slept.append($0) })
        XCTAssertNil(got)
        XCTAssertEqual(log.reads, 3)
        XCTAssertEqual(log.slept, [1, 2], "waits between reads only")
        XCTAssertEqual(StaleCopyRefresh.worstCaseDelay, 3)
    }
}

final class BadgePlacementTests: XCTestCase {
    /// #251: when the consent button hides the badge gets narrower. It keeps its left edge instead of re-centring,
    /// which moved Stop under the pointer.
    /// Mutation: BadgePlacement.originX, ignore `anchoredLeft` -> RED.
    func testAShrinkingBadgeKeepsItsLeftEdge() {
        XCTAssertEqual(BadgePlacement.originX(anchoredLeft: 500, width: 300, screenMidX: 720), 500)
        XCTAssertEqual(BadgePlacement.originX(anchoredLeft: nil, width: 300, screenMidX: 720), 570, "a new badge is centred")
    }

    private let laptop = BadgePlacement.Screen(id: 1, minX: 0, maxX: 1440, maxY: 875)
    private let external = BadgePlacement.Screen(id: 2, minX: 1440, maxX: 3360, maxY: 1055)

    /// #342.4: a display change re-places the badge on the screen it is on, keeping its left edge.
    /// Mutation: BadgePlacement.place, `let kept = ...` -> `let kept: Screen? = nil` -> RED (it jumps to the main screen).
    func testABadgeStaysOnItsScreenWhenAnotherOneChanges() {
        let p = BadgePlacement.place(screens: [laptop, external], placedOn: 2, main: 1, anchoredLeft: 2000, width: 300, height: 36)
        XCTAssertEqual(p, BadgePlacement.Placement(screenID: 2, x: 2000, y: 1055 - 36 - 8))
    }

    /// #342.4: the screen the badge was on is unplugged: it moves to the main screen, centred, not left off screen.
    /// Mutation: BadgePlacement.place, `let left = kept == nil ? nil : anchoredLeft` -> `let left = anchoredLeft` -> RED.
    func testABadgeWhoseScreenWentMovesToTheMainScreenCentred() {
        let p = BadgePlacement.place(screens: [laptop], placedOn: 2, main: 1, anchoredLeft: 2000, width: 300, height: 36)
        XCTAssertEqual(p, BadgePlacement.Placement(screenID: 1, x: 570, y: 875 - 36 - 8))
    }

    /// Mutation: BadgePlacement.place, drop the `main.flatMap` arm -> RED (the first screen is taken instead).
    func testTheMainScreenIsPreferredOverTheFirstOne() {
        let p = BadgePlacement.place(screens: [laptop, external], placedOn: nil, main: 2, anchoredLeft: nil, width: 300, height: 36)
        XCTAssertEqual(p?.screenID, 2)
        XCTAssertEqual(p?.x, 2400 - 150)
        let none = BadgePlacement.place(screens: [laptop, external], placedOn: 9, main: 8, anchoredLeft: nil, width: 300, height: 36)
        XCTAssertEqual(none?.screenID, 1, "neither is there: the first screen")
    }

    /// Mutation: BadgePlacement.place, `return Placement(...)` with `x` instead of `inside` -> RED.
    func testASmallerScreenPullsTheBadgeBackInside() {
        // The screen it is on shrank (a resolution change): the old left edge would put the badge half off it.
        let shrunk = BadgePlacement.Screen(id: 1, minX: 0, maxX: 1024, maxY: 700)
        let p = BadgePlacement.place(screens: [shrunk], placedOn: 1, main: 1, anchoredLeft: 1000, width: 300, height: 36)
        XCTAssertEqual(p?.x, 724)
        let left = BadgePlacement.place(screens: [shrunk], placedOn: 1, main: 1, anchoredLeft: -50, width: 300, height: 36)
        XCTAssertEqual(left?.x, 0)
        let wide = BadgePlacement.place(screens: [BadgePlacement.Screen(id: 1, minX: 0, maxX: 200, maxY: 700)],
                                        placedOn: 1, main: 1, anchoredLeft: 40, width: 300, height: 36)
        XCTAssertEqual(wide?.x, 0, "a badge wider than the screen starts at its edge")
    }

    func testNoScreensIsNoPlacement() {
        XCTAssertNil(BadgePlacement.place(screens: [], placedOn: 1, main: 1, anchoredLeft: 10, width: 300, height: 36))
    }
}
