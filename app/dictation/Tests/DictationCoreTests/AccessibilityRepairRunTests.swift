import XCTest
@testable import DictationCore

/// #129 — the tccutil reset runs off the main thread; here the process is a
/// fake, so nothing real is ever reset.
final class AccessibilityRepairRunTests: XCTestCase {
    private final class FakeLauncher {
        var launched: [[String]] = []
        var exits: [(Int32) -> Void] = []
        var throwOnLaunch = false
        struct Boom: Error {}
        func launch(_ arguments: [String], _ onExit: @escaping (Int32) -> Void) throws {
            if throwOnLaunch { throw Boom() }
            launched.append(arguments)
            exits.append(onExit)
        }
    }

    private let id = "io.github.anatolykoptev.ox-say.dictation"

    /// Starting returns at once with the process still running; the result
    /// arrives from the exit callback, never from a wait.
    /// Mutation: call completion inside start() instead of the exit handler -> RED.
    func testStartDoesNotWaitForTheProcess() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, completion: { results.append($0) }), .started)
        XCTAssertEqual(fake.launched, [["reset", "Accessibility", id]])
        XCTAssertTrue(run.isRunning)
        XCTAssertTrue(results.isEmpty, "the result must wait for the process to exit")
        fake.exits[0](0)
        XCTAssertEqual(results, [true])
        XCTAssertFalse(run.isRunning)
    }

    /// A second click while the first reset runs starts nothing.
    /// Mutation: drop the isRunning guard in start() -> RED.
    func testASecondStartWhileRunningIsRefused() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        _ = run.start(bundleID: id, launch: fake.launch, completion: { _ in })
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, completion: { _ in }), .busy)
        XCTAssertEqual(fake.launched.count, 1)
    }

    /// A non-zero exit is a failure, and the run is free again afterwards.
    func testNonZeroExitFailsAndFreesTheRun() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        var results: [Bool] = []
        _ = run.start(bundleID: id, launch: fake.launch, completion: { results.append($0) })
        fake.exits[0](1)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, completion: { _ in }), .started)
    }

    /// A launch that throws never leaves the run "busy" for good.
    func testALaunchFailureFreesTheRun() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        fake.throwOnLaunch = true
        XCTAssertEqual(run.start(bundleID: id, launch: fake.launch, completion: { _ in }), .launchFailed)
        XCTAssertFalse(run.isRunning)
    }

    /// No usable bundle id: nothing is launched.
    func testNoBundleIDLaunchesNothing() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        XCTAssertEqual(run.start(bundleID: " ", launch: fake.launch, completion: { _ in }), .unavailable)
        XCTAssertTrue(fake.launched.isEmpty)
    }

    /// A process that reports its exit twice completes once.
    func testADoubleExitCompletesOnce() {
        let fake = FakeLauncher(); let run = AccessibilityRepairRun()
        var count = 0
        _ = run.start(bundleID: id, launch: fake.launch, completion: { _ in count += 1 })
        fake.exits[0](0); fake.exits[0](0)
        XCTAssertEqual(count, 1)
    }
}

/// #129 — the wiring around the runner: no blocking wait on main, the item
/// greyed while the reset runs, one UI after it, a separator under the top rows.
final class AccessibilityRepairWiringTests: XCTestCase {
    private static var source: String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private func body(_ signature: String) -> String {
        let s = Self.source
        guard let start = s.range(of: signature),
              let end = s.range(of: "\n    }\n", range: start.upperBound..<s.endIndex)
        else { XCTFail("\(signature) not found"); return "" }
        return String(s[start.lowerBound..<end.upperBound])
    }

    /// Mutation: re-add `reset.waitUntilExit()` to allowPasting -> RED.
    func testAllowPastingNeverBlocksTheMainThread() {
        let b = body("@objc private func allowPasting() {")
        XCTAssertFalse(b.contains("waitUntilExit"), "tccutil is awaited on the main thread")
        XCTAssertTrue(b.contains("repairRun.start("), "the reset must go through AccessibilityRepairRun")
        XCTAssertTrue(b.contains("allowPastingItem.isEnabled = false"), "the item stays clickable while the reset runs")
        XCTAssertTrue(b.contains("allowPastingItem.isEnabled = true"), "the item is never re-enabled")
    }

    /// The system prompt carries its own "Open System Settings" button; opening
    /// the pane as well shows two UIs at once.
    /// Mutation: re-add `openAccessibilitySettings()` to allowPasting -> RED.
    func testAllowPastingOpensOneUINotTwo() {
        XCTAssertFalse(body("@objc private func allowPasting() {").contains("openAccessibilitySettings()"))
    }

    /// Mutation: delete the separator before the status line in buildMenu -> RED.
    func testASeparatorSitsUnderTheTopRows() {
        let b = body("private func buildMenu() {")
        guard let sep = b.range(of: "menu.addItem(.separator())"),
              let status = b.range(of: "menu.addItem(statusLine)") else { return XCTFail("buildMenu changed shape") }
        XCTAssertLessThan(sep.lowerBound, status.lowerBound, "the top rows run straight into the status line")
    }
}
