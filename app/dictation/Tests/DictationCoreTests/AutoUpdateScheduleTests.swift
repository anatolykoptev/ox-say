import XCTest
@testable import DictationCore

final class AutoUpdateScheduleTests: XCTestCase {
    private typealias Fetch = Result<(tag: String, url: URL?, body: String), UpdateError>
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func release(_ tag: String) -> Fetch {
        .success((tag, URL(string: "https://github.com/x/y/releases/tag/\(tag)"), "notes"))
    }

    /// One slot as the app runs it: load the persisted state, fold the fetch
    /// in, save it back.
    private func slot(_ fetch: Fetch, local: String, now: Date, defaults: UserDefaults) -> AutoUpdateSchedule.Outcome {
        var state = AutoUpdateState.load(from: defaults)
        let outcome = AutoUpdateSchedule.apply(fetch: fetch, local: local, now: now, state: &state)
        // The notice a raised offer carries is shown at once here (nothing dictates).
        if case .offer(let tag, true) = outcome {
            AutoUpdateSchedule.noticeShown(.updateAvailable("m", tag: tag), state: &state)
        }
        state.save(to: defaults)
        return outcome
    }

    /// A throwaway defaults domain; the caller removes it with `drop`.
    private func freshDefaults(_ name: String = #function) -> (defaults: UserDefaults, drop: () -> Void) {
        let suite = "AutoUpdateScheduleTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // F1 — mutation: in AutoUpdateSchedule.apply, replace
    // `let notify = state.lastNotifiedVersion != remote` with `let notify = true` -> RED.
    func testOlderLocalOffersTheRowAndNotifiesOncePerVersionAcrossLaunches() {
        let (defaults, drop) = freshDefaults()
        defer { drop() }
        XCTAssertEqual(slot(release("v0.1.23"), local: "0.1.22", now: t0, defaults: defaults),
                       .offer(tag: "v0.1.23", notify: true), "the first slot raises the notice")
        XCTAssertEqual(slot(release("v0.1.23"), local: "0.1.22", now: t0.addingTimeInterval(86_400), defaults: defaults),
                       .offer(tag: "v0.1.23", notify: false), "a second evaluation for the same version stays quiet but keeps the row")
        // A relaunch reads the same defaults and builds the row again, silently.
        XCTAssertEqual(slot(release("v0.1.23"), local: "0.1.22", now: t0.addingTimeInterval(90_000), defaults: defaults),
                       .offer(tag: "v0.1.23", notify: false), "a relaunch must not repeat the notice")
        XCTAssertEqual(AutoUpdateState.load(from: defaults).lastNotifiedVersion, "v0.1.23")
        XCTAssertEqual(slot(release("v0.1.24"), local: "0.1.22", now: t0.addingTimeInterval(200_000), defaults: defaults),
                       .offer(tag: "v0.1.24", notify: true), "a newer release is a new notice")
    }

    func testCurrentOrNewerLocalClearsTheRowAndNeverNotifies() {
        let (defaults, drop) = freshDefaults()
        defer { drop() }
        XCTAssertEqual(slot(release("v0.1.23"), local: "0.1.23", now: t0, defaults: defaults), .clear)
        XCTAssertEqual(slot(release("v0.1.22"), local: "0.1.23", now: t0, defaults: defaults), .clear)
        XCTAssertNil(AutoUpdateState.load(from: defaults).lastNotifiedVersion)
    }

    func testAFailedCheckChangesNothingAndIsRetriedAtTheNextSlot() {
        let (defaults, drop) = freshDefaults()
        defer { drop() }
        _ = slot(release("v0.1.23"), local: "0.1.22", now: t0, defaults: defaults)
        let before = AutoUpdateState.load(from: defaults)
        for error in [UpdateError.unreachable("offline"), .http(403), .badResponse] {
            XCTAssertEqual(slot(.failure(error), local: "0.1.22", now: t0.addingTimeInterval(7_200), defaults: defaults), .unchanged)
        }
        XCTAssertEqual(AutoUpdateState.load(from: defaults), before, "a failure must not spend the 24 h or the notice")
        XCTAssertTrue(AutoUpdateSchedule.shouldCheck(now: t0.addingTimeInterval(7_200),
                                                     lastCheck: nil, answeredThisProcess: false), "never answered: due at the next tick")
    }

    func testTheVersionCompareIsTheManualChecksOwn() {
        // 0.1.9 -> 0.1.10 is the case a string compare gets wrong.
        var state = AutoUpdateState()
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: release("v0.1.10"), local: "0.1.9", now: t0, state: &state),
                       .offer(tag: "v0.1.10", notify: true))
        var garbage = AutoUpdateState()
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: release("latest"), local: "0.1.9", now: t0, state: &garbage), .clear)
    }

    // F2 — mutation: `public static let interval: TimeInterval = 24 * 60 * 60` ->
    // `24 * 60` (24 minutes), or `shouldCheck` returning true early -> RED.
    func testTwentyFourHourThrottle() {
        func due(after seconds: TimeInterval) -> Bool {
            AutoUpdateSchedule.shouldCheck(now: t0.addingTimeInterval(seconds), lastCheck: t0, answeredThisProcess: true)
        }
        XCTAssertFalse(due(after: 25 * 60), "25 minutes after a check is not due")
        XCTAssertFalse(due(after: 12 * 3_600))
        XCTAssertFalse(due(after: 24 * 3_600 - 1))
        XCTAssertTrue(due(after: 24 * 3_600))
        XCTAssertTrue(due(after: 30 * 3_600))
    }

    // F6 — mutation: restore the launch-slot-only rule, i.e. make `shouldCheck`
    // ignore `answeredThisProcess` (`if false { return true }`) -> RED.
    func testAProcessThatHasNoAnswerYetIsDueEvenWithinTheDayOfTheLastOne() {
        // The previous launch got an answer 2 h ago; this launch's 60 s check
        // failed (Wi-Fi not up) or was skipped. The next tick, 1 h later, must retry.
        let previous = t0.addingTimeInterval(-2 * 3_600)
        XCTAssertTrue(AutoUpdateSchedule.shouldCheck(now: t0.addingTimeInterval(3_600), lastCheck: previous,
                                                     answeredThisProcess: false),
                      "a process with no answer yet leaves the row missing until 24 h after the old answer")
        XCTAssertFalse(AutoUpdateSchedule.shouldCheck(now: t0.addingTimeInterval(3_600), lastCheck: previous,
                                                      answeredThisProcess: true),
                       "once this process got an answer the 24 h throttle holds")
    }

    func testAClockMovedBackIsDueAndTheLaunchDelayIsSixtySeconds() {
        XCTAssertTrue(AutoUpdateSchedule.shouldCheck(now: t0, lastCheck: t0.addingTimeInterval(3_600), answeredThisProcess: true),
                      "a last check in the future must not silence checks for good")
        XCTAssertEqual(AutoUpdateSchedule.firstDelay, 60)
    }

    func testDisplayVersionAlwaysCarriesOneV() {
        XCTAssertEqual(AutoUpdateSchedule.displayVersion("v0.1.23"), "v0.1.23")
        XCTAssertEqual(AutoUpdateSchedule.displayVersion("0.1.23"), "v0.1.23")
    }

    func testTheUpdateRowSitsAboveEveryOtherTopRow() {
        let plan = TopRows.plan(current: [.repair, .openOxSay], wantRepair: true, wantAllowPasting: false, wantUpdate: true)
        var rows: [TopRow] = [.repair, .openOxSay]
        for row in plan.remove { rows.removeAll { $0 == row } }
        for ins in plan.insert { rows.insert(ins.row, at: min(ins.index, rows.count)) }
        XCTAssertEqual(rows, [.update, .repair, .openOxSay])
        // Retracted again once the build is current.
        let gone = TopRows.plan(current: rows, wantRepair: true, wantAllowPasting: false, wantUpdate: false)
        XCTAssertTrue(gone.remove.contains(.update))
    }
}

/// The AppKit side of the background check, gated by reading the sources —
/// the style of `NeverLoseWiringTests`.
final class AutoUpdateWiringTests: XCTestCase {
    private static func source(_ file: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DictationCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources/OxSayDictation/\(file)")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private func requireBody(_ signature: String) -> String {
        let source = Self.source("AppDelegate.swift")
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)
        else { XCTFail("AppDelegate.swift: `\(signature)` not found — the wiring guard has nothing to check"); return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    // F3 — mutation: call `checkForUpdates()` (the manual path) from the launch
    // timer, the tick or the wake observer -> RED.
    func testEverySlotRunsTheBackgroundCheckNeverTheManualOne() {
        let arm = requireBody("private func startAutoUpdateChecks() {")
        XCTAssertTrue(arm.contains("AutoUpdateSchedule.firstDelay") && arm.contains("AutoUpdateSchedule.tick"), "the launch timer or the tick is gone")
        XCTAssertEqual(arm.components(separatedBy: "self?.backgroundUpdateCheck()").count - 1, 2,
                       "the launch timer and the tick must both run the background check")
        XCTAssertFalse(arm.contains("checkForUpdates"), "a timer reaches the manual check: its working pill and alert")
        let source = Self.source("AppDelegate.swift")
        guard let wake = source.range(of: "NSWorkspace.didWakeNotification"),
              let armed = source.range(of: "startAutoUpdateChecks()", range: wake.upperBound..<source.endIndex)
        else { return XCTFail("the wake observer or the arming call is gone") }
        let observer = String(source[wake.lowerBound..<armed.lowerBound])
        XCTAssertTrue(observer.contains("backgroundUpdateCheck()"), "a wake does not re-evaluate the update check")
        XCTAssertFalse(observer.contains("checkForUpdates"), "a wake reaches the manual check")
    }

    // Mutation: add `overlay.showWorking()` / `runAlert(` to the background
    // check, or drop its UpdateGate guard -> RED.
    func testBackgroundCheckShowsNoPillNoAlertAndSkipsAnInstall() {
        let check = requireBody("private func backgroundUpdateCheck(")
        for forbidden in ["checkForUpdates", "showWorking", "setWorkingText", "runAlert", "confirmInstall", "installUpdate", "present("] {
            XCTAssertFalse(check.contains(forbidden), "the background check calls `\(forbidden)`")
        }
        XCTAssertTrue(check.contains("UpdateGate.decide(installing: updateInstalling) == .proceed"),
                      "the background check can run while an install does")
        XCTAssertTrue(check.contains("self.notice(.updateAvailable(L10nKey.noticeUpdateAvailable"), "the notice does not go through notice() and NoticeGate")
        XCTAssertTrue(check.contains("AutoUpdateSchedule.apply(") && check.contains("state.save(to:"),
                      "the outcome is not persisted — the notice would repeat every launch")
    }

    // Mutation: have the row call `checkForUpdates()` or drop the install -> RED.
    func testTheRowInstallsTheOfferedTagOnlyOnAClick() {
        let row = requireBody("@objc private func installOfferedUpdate() {")
        XCTAssertTrue(row.contains("installUpdate(tag: tag, kind: .update)"))
        XCTAssertTrue(row.contains("UpdateGate.decide(installing: updateInstalling) == .proceed"))
        let check = requireBody("private func backgroundUpdateCheck(")
        XCTAssertFalse(check.contains("installOfferedUpdate"), "the background check installs on its own")
    }

    // F4 — mutation: delete the `guard AutoUpdateSchedule.shouldCheck(` statement in
    // backgroundUpdateCheck -> RED (every hourly tick would hit the GitHub API).
    // Also: drop either UpdateGate guard, or move the schedule guard after the request.
    func testTheScheduleAndBothInstallGatesWrapTheRequest() {
        let check = requireBody("private func backgroundUpdateCheck(")
        func at(_ needle: String) -> String.Index? { check.range(of: needle)?.lowerBound }
        guard let before = at("guard UpdateGate.decide(installing: updateInstalling) == .proceed"),
              let schedule = at("guard AutoUpdateSchedule.shouldCheck(now: Date(), lastCheck: AutoUpdateState.load(from: autoUpdateDefaults).lastCheck,"),
              let answered = at("answeredThisProcess: autoUpdateAnswered) else { return }"),
              let running = at("autoUpdateRunning = true"),
              let request = at("self.updater.fetchResult()"),
              let after = at("guard UpdateGate.decide(installing: self.updateInstalling) == .proceed else { return }"),
              let apply = at("AutoUpdateSchedule.apply(")
        else { return XCTFail("backgroundUpdateCheck lost the schedule guard, an UpdateGate check or the request") }
        XCTAssertTrue(before < schedule && schedule < answered && answered < running && running < request,
                      "the install gate and the 24 h schedule must both be decided before the request goes out")
        XCTAssertTrue(request < after && after < apply, "an install that began while the request was out must be re-checked before the outcome is applied")
        XCTAssertTrue(check.contains("if outcome != .unchanged { self.autoUpdateAnswered = true }"),
                      "an answered check is not remembered: the throttle never starts, or never relaxes after a failed launch check")
    }

    // F5 — mutation: `wantUpdate: false` in syncTopRows, or drop the
    // `applyStatusIcon()` after the outcome (or in show()) -> RED.
    func testTheOutcomeReachesTheRowAndTheDot() {
        let sync = requireBody("private func syncTopRows(in menu: NSMenu) {")
        XCTAssertTrue(sync.contains("wantUpdate: updateOffer != nil"), "the Update row is not driven by the offer")
        let icon = requireBody("private func applyStatusIcon() {")
        XCTAssertTrue(icon.contains("guard updateOffer != nil else {"), "the status dot is not driven by the offer")
        let check = requireBody("private func backgroundUpdateCheck(")
        guard let notice = check.range(of: "self.notice(.updateAvailable(L10nKey.noticeUpdateAvailable"),
              let rows = check.range(of: "self.syncTopRows(in: menu)", range: notice.upperBound..<check.endIndex),
              let dot = check.range(of: "self.applyStatusIcon()", range: rows.upperBound..<check.endIndex)
        else { return XCTFail("the outcome no longer re-syncs the menu rows and then the status icon") }
        XCTAssertTrue(check.contains("if let menu = self.statusItem.menu { self.syncTopRows(in: menu) }"))
        XCTAssertTrue(dot.lowerBound > notice.lowerBound)
        // Every later icon redraw (a dictation state change) must keep the dot too.
        let show = requireBody("private func show(_ state: DictationState) {")
        XCTAssertTrue(show.contains("applyStatusIcon()"), "show() draws the icon without the update dot")
    }

    // F7 — mutation: remove the `guard controller.state == .idle` in
    // installOfferedUpdate -> RED (the installer quits the app mid-dictation).
    func testTheRowDoesNotInstallDuringADictation() {
        let row = requireBody("@objc private func installOfferedUpdate() {")
        guard let idle = row.range(of: "guard controller.state == .idle else {"),
              let install = row.range(of: "installUpdate(tag: tag, kind: .update)")
        else { return XCTFail("installOfferedUpdate lost its idle gate or the install") }
        XCTAssertTrue(idle.lowerBound < install.lowerBound, "the idle gate must come before the install")
    }

    // Mutation: add the timers with `Timer.scheduledTimer` (default mode only)
    // -> RED (the check stalls while the status-bar menu is open).
    func testTheTimersRunInCommonModes() {
        let arm = requireBody("private func startAutoUpdateChecks() {")
        XCTAssertFalse(arm.contains("scheduledTimer"), "default-mode timers pause while a menu is tracking")
        XCTAssertTrue(arm.contains("for timer in timers { RunLoop.main.add(timer, forMode: .common) }"),
                      "the timers are not added to the common run-loop modes")
        XCTAssertTrue(arm.contains("autoUpdateTimers = timers"), "the added timers are not the ones kept")
    }
}
