import AppKit
import XCTest
@testable import DictationCore

/// The recording plate, the record prompt and the dictation pill must be on screen over another app's full-screen
/// Space (#517). Apple DTS (developer.apple.com/forums/thread/826308): an `.accessory` app, a non-activating NSPanel,
/// level `.screenSaver` (`.statusBar` sits BELOW full-screen content) and `.canJoinAllApplications`.
final class PlateVisibilityTests: XCTestCase {
    @MainActor
    private func panel() -> NSPanel {
        NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    /// Mutation: PlateWindowSpec.level, `.screenSaver` -> `.statusBar` -> RED.
    @MainActor
    func testAppliedPanelIsAboveFullScreenContent() {
        let p = panel()
        PlateWindowSpec.apply(to: p)
        XCTAssertEqual(p.level, .screenSaver)
        XCTAssertTrue(p.isFloatingPanel)
        XCTAssertFalse(p.hidesOnDeactivate)
    }

    /// Mutation: PlateWindowSpec.collectionBehavior, drop `.canJoinAllApplications` -> RED.
    @MainActor
    func testAppliedPanelJoinsEverySpaceOfEveryApp() {
        let p = panel()
        PlateWindowSpec.apply(to: p)
        for flag in [NSWindow.CollectionBehavior.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary] {
            XCTAssertTrue(p.collectionBehavior.contains(flag), "missing \(flag)")
        }
        XCTAssertFalse(p.collectionBehavior.contains(.moveToActiveSpace), "moveToActiveSpace and canJoinAllSpaces exclude each other")
    }

    @MainActor
    func testExtraBehaviourIsAdded() {
        let p = panel()
        PlateWindowSpec.apply(to: p, extra: .ignoresCycle)
        XCTAssertTrue(p.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(p.collectionBehavior.contains(.canJoinAllApplications))
    }

    // MARK: PlateWatch

    private func run(_ w: inout PlateWatch, _ seq: [Bool]) -> [[PlateWatch.Action]] {
        seq.map { w.observe(onscreen: $0, expected: true) }
    }

    /// Mutation: PlateWatch.observe, `} else if !told {` -> `} else if false {` (never tells the user) -> RED.
    func testAMissIsReorderedOnceThenToldOncePerOutage() {
        var w = PlateWatch()
        let out = run(&w, [false, false, false, false])
        XCTAssertEqual(out[0], [.log(.missed(1)), .reorder])
        XCTAssertEqual(out[1], [.log(.missed(2)), .tell])
        XCTAssertEqual(out[2], [.log(.missed(3))])
        XCTAssertEqual(out[3], [], "told once per episode, not every poll")
    }

    /// Mutation: PlateWatch.observe, drop the `told = false` reset on recovery -> RED (second episode never told).
    func testRecoveryIsLoggedAndANewEpisodeIsToldAgain() {
        var w = PlateWatch()
        _ = run(&w, [false, false])
        XCTAssertEqual(w.observe(onscreen: true, expected: true), [.log(.recovered)])
        XCTAssertEqual(w.observe(onscreen: true, expected: true), [])
        let out = run(&w, [false, false])
        XCTAssertEqual(out[1], [.log(.missed(2)), .tell])
    }

    func testLockedScreenIsNotAFault() {
        var w = PlateWatch()
        XCTAssertEqual(w.observe(onscreen: false, expected: false), [])
        XCTAssertEqual(w.observe(onscreen: false, expected: true), [.log(.missed(1)), .reorder],
                       "a locked-screen poll does not count as a miss")
    }

    func testLogIsNotSpammedOnALongOutage() {
        var w = PlateWatch()
        var logs = 0
        for _ in 0..<100 {
            if w.observe(onscreen: false, expected: true).contains(where: { if case .log = $0 { return true }; return false }) { logs += 1 }
        }
        XCTAssertLessThan(logs, 15)
    }

    // MARK: collapse

    /// A recording is never invisible: collapsed is a small pill, not a hidden panel.
    func testACollapsedPlateIsStillOnScreen() {
        for recording in [true, false] {
            for collapsed in [true, false] {
                let p = PlateCollapse.presentation(isRecording: recording, userCollapsed: collapsed)
                if recording { XCTAssertTrue(p.panelVisible) }
                if !recording { XCTAssertEqual(p, .expanded, "prompts, questions and errors are never collapsed") }
            }
        }
        XCTAssertEqual(PlateCollapse.presentation(isRecording: true, userCollapsed: true), .collapsed)
    }
}
