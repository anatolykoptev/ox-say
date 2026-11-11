import XCTest
@testable import DictationCore

/// The app target is not compiled by the shim: what the AppKit glue must DO is decided in DictationCore (tested there);
/// these tests read the sources WITHOUT comments and pin that the decisions are called from the place that matters.
/// Issues #517 (invisible over a full-screen call), #518 (an answered prompt did not record, nothing logged), #519
/// (black menu-bar icon), #520 (drag + collapse).
final class MeetingPlateWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    private func |\n    func |\n    @discardableResult\n    |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    private func controller() throws -> String { try source("OxSayDictation/MeetingController.swift") }
    private func badge() throws -> String { try source("OxSayDictation/MeetingBadge.swift") }
    private func overlay() throws -> String { try source("OxSayDictation/Overlay.swift") }

    // MARK: #517 windows

    /// Mutation: MeetingBadge.init, replace `PlateWindowSpec.apply(to: panel)` with `panel.level = .statusBar` -> RED.
    func testBothPanelsTakeTheirWindowConfigurationFromTheOneSpec() throws {
        let b = try badge()
        XCTAssertTrue(b.contains("PlateWindowSpec.apply(to: panel)"))
        XCTAssertFalse(b.contains("panel.level ="), "no second, hand-written level")
        XCTAssertFalse(b.contains("collectionBehavior"), "no second, hand-written behaviour")
        let o = try overlay()
        XCTAssertTrue(o.contains("PlateWindowSpec.apply(to: panel, extra: .ignoresCycle)"))
        XCTAssertFalse(o.contains("panel.level ="))
        XCTAssertFalse(o.contains("collectionBehavior"))
    }

    /// The plate is checked while it is up, not only when it appears: the user changes Space after it was shown.
    /// Mutation: MeetingBadge.verify, delete `case .holdAccessory:` handling -> RED.
    func testTheBadgeChecksItselfAgainstTheWindowServerAndEscalates() throws {
        let b = try badge()
        let verify = try XCTUnwrap(body(b, of: "func verifyOnScreen() {"))
        XCTAssertTrue(verify.contains("watch.observe(onscreen: state.onscreen && state.alpha >= 1, expected: PlateProbe.expectsOnscreen(panel), policy: policy)"))
        XCTAssertTrue(verify.contains("case .reorder: panel.orderFrontRegardless()"))
        XCTAssertTrue(verify.contains("case .holdAccessory:"))
        XCTAssertTrue(verify.contains("PlatePolicyHold.shared.set(\"meeting\", held: true)"))
        XCTAssertTrue(verify.contains("case .tell: onNotVisible?()"))
        XCTAssertTrue(verify.contains("badgeLog.fault("), "a plate that cannot be seen is a fault in the log")
        let hide = try XCTUnwrap(body(b, of: "func hide() {"))
        XCTAssertTrue(hide.contains("PlatePolicyHold.shared.set(\"meeting\", held: false)"), "the hold ends with the plate")
        let c = try controller()
        XCTAssertTrue(c.contains("badge.onNotVisible = { [weak self] in self?.plateNotVisible() }"))
        let tell = try XCTUnwrap(body(c, of: "private func plateNotVisible() {"))
        XCTAssertTrue(tell.contains("notifier.post("), "the existing notifier, which does show over a full-screen Space")
        XCTAssertTrue(tell.contains("host.notify("))
        let tick = try XCTUnwrap(body(c, of: "@objc private func refreshBadge() {"))
        XCTAssertTrue(tick.contains("badge.verifyOnScreen()"), "while recording, every few seconds")
    }

    func testTheDictationPillEscalatesTheSameWay() throws {
        let o = try overlay()
        let check = try XCTUnwrap(body(o, of: "private func checkVisible(expected: Int, owner ownerAtShow: Int) {"))
        XCTAssertTrue(check.contains("watch.observe(onscreen:"))
        XCTAssertTrue(check.contains("PlatePolicyHold.shared.set(\"overlay\", held: true)"))
        try XCTAssertTrue(overlay().contains("PlatePolicyHold.shared.set(\"overlay\", held: false)"))
    }

    /// The activation policy follows the hold: a `.regular` app's panels do not join another app's full-screen Space.
    /// Mutation: MainWindow.applyPolicy, drop `PlatePolicyHold.shared.effective(` -> RED.
    func testTheMainWindowPolicyRespectsThePlateHold() throws {
        let m = try source("OxSayDictation/MainWindow.swift")
        let apply = try XCTUnwrap(body(m, of: "private func applyPolicy() {"))
        XCTAssertTrue(apply.contains("PlatePolicyHold.shared.effective("))
        let open = try XCTUnwrap(body(m, of: "func open(route: MainRoute? = nil) {"))
        XCTAssertTrue(open.contains("NSApp.setActivationPolicy(PlatePolicyHold.shared.effective(.regular).nsPolicy)"))
        XCTAssertFalse(open.contains("setActivationPolicy(.regular)"))
        XCTAssertTrue(m.contains("PlatePolicyHold.shared.onChange"))
    }

    // MARK: #518 prompt -> record

    /// An answered Record never waits behind a window the user may not see: no modal alert on the way to the recording.
    /// Mutation: MeetingController.start, restore `!consentReminderAccepted()` before the Task -> RED.
    func testNoModalStandsBetweenAnAnsweredPromptAndTheRecording() throws {
        let c = try controller()
        let start = try XCTUnwrap(body(c, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertFalse(start.contains("host.alert"))
        XCTAssertFalse(start.contains("consentReminderAccepted"))
        XCTAssertFalse(c.contains("consentReminderAccepted"))
        XCTAssertFalse(c.contains("host.alert(L10nKey.meetingRemindTitle"), "the reminder is a notification now")
        let recorded = try XCTUnwrap(start.range(of: "try recorder.start(into:"))
        let reminded = try XCTUnwrap(start.range(of: "if origin == .auto || offered { noteConsentReminder() }"))
        XCTAssertLessThan(recorded.lowerBound, reminded.lowerBound, "the reminder follows the start, never gates it")
        let note = try XCTUnwrap(body(c, of: "private func noteConsentReminder() {"))
        XCTAssertTrue(note.contains("notifier.post(title: title, body: ConsentReminder.body("))
        XCTAssertTrue(note.contains("let title = L10nKey.meetingRemindTitle.text"))
        XCTAssertTrue(note.contains("ConsentReminder.body(retention: MeetingSettings.retention(host.defaults), text: { $0.text })"))
        XCTAssertFalse(note.contains("setCallMode"))
        XCTAssertFalse(note.contains("createDirectory(") && !note.contains("Task.detached"), "the folder (a macOS permission prompt) never blocks the main thread")
    }

    /// Every way a start does not become a recording says why, in the log and on the plate. No silent exit.
    /// Mutation: MeetingController.start, delete the `MeetingTrace.Event.startRefused` line of the first guard -> RED.
    func testEveryStartExitIsLoggedAndAFailureIsVisible() throws {
        let c = try controller()
        let start = try XCTUnwrap(body(c, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        XCTAssertTrue(start.contains("trace(.startRequested(origin:"))
        XCTAssertTrue(start.contains("guard current == nil, !starting, !isShutDown else {\n            trace(.startRefused(reason: current != nil ? \"already_recording\" : starting ? \"already_starting\" : \"shut_down\"))"))
        XCTAssertTrue(start.contains("trace(.startRefused(reason: \"update_installing\"))"))
        XCTAssertTrue(start.contains("trace(.started(id: info.id, origin:"))
        XCTAssertGreaterThanOrEqual(start.components(separatedBy: "failStart(").count - 1, 2, "mic permission and the daemon/recorder failure")
        let fail = try XCTUnwrap(body(c, of: "private func failStart(_ error: Error) {"))
        XCTAssertTrue(fail.contains("trace(.startFailed(reason: MeetingTrace.reason(of: error)))"))
        XCTAssertTrue(fail.contains("badge.showError("), "persistent, on the plate")
        XCTAssertTrue(fail.contains("notifier.post("), "and where the plate cannot be seen")
        XCTAssertTrue(fail.contains("host.notify("))
        // The settle that follows a failed start must not take the error down.
        let settle = try XCTUnwrap(body(c, of: "private func settleBadge(started: Bool, began: Bool = true, pressed: String?) {"))
        XCTAssertFalse(settle.contains(".failed"), "an error is not a question: settle leaves it")
    }

    /// Mutation: MeetingController.recordFromPrompt, delete `trace(.answered(.record,` -> RED.
    func testThePromptTransitionsAreLogged() throws {
        let c = try controller()
        let press = try XCTUnwrap(body(c, of: "private func recordFromPrompt() {"))
        XCTAssertTrue(press.contains("trace(.answered(.record, app: CallPolicy.name(for:"))
        XCTAssertTrue(press.contains("trace(.checked("))
        let answer = try XCTUnwrap(body(c, of: "private func answerRecordQuestion(_ answer: RecordPrompt.Answer) {"))
        XCTAssertTrue(answer.contains("trace(.answered("))
        XCTAssertTrue(c.contains("trace(.promptShown(app: CallPolicy.name(for: source)))"))
        XCTAssertTrue(c.contains("badge.onNotNow = { [weak self] in\n            self?.trace(.answered(.notNow,"))
        let dontAsk = try XCTUnwrap(body(c, of: "private func dontAskForThisApp() {"))
        XCTAssertTrue(dontAsk.contains("trace(.answered(.dontAsk,"))
        try XCTAssertTrue(XCTUnwrap(body(c, of: "func stop() {")).contains("trace(.stopped(id: info.id, why: \"user\"))"))
    }

    /// #6 auto mode: a detected call starts the recording itself — the only thing between the tick and the daemon is
    /// the pure policy; nothing is drawn first.
    /// Mutation: MeetingController.observe, `case .start: start(origin: .auto, source: source)` -> `badge.showPrompt(...)` -> RED.
    func testAnAutoCallStartsWithoutAVisibleStep() throws {
        let c = try controller()
        let observe = try XCTUnwrap(body(c, of: "private func observe(_ tick: CallWatcher.Tick) {"))
        XCTAssertTrue(observe.contains("case .start:\n                trace(.autoStarting(app: CallPolicy.name(for: source)))\n                start(origin: .auto, source: source)"))
        let start = try XCTUnwrap(body(c, of: "private func start(origin: CallTracker.Origin, source: String, offered: Bool = false) {"))
        let before = try XCTUnwrap(start.range(of: "host.client.createMeeting(")).lowerBound
        let guardPart = String(start[..<before])
        for visible in ["host.alert", "badge.showPrompt", "badge.showRecordConfirm", "NSAlert", "runModal"] {
            XCTAssertFalse(guardPart.contains(visible), "\(visible) before the daemon is asked")
        }
    }

    func testAutoModeStartsEveryKnownSourceUnlessInstalling() {
        for source in CallPolicy.sources {
            // Under global auto the work-call apps start by themselves; a messenger is asked about (CallPolicy.defaultMode).
            let expected: MeetingPolicy.CallStart = CallDetector.autoStartSources.contains(source) ? .start : .prompt
            XCTAssertEqual(MeetingPolicy.onCallStarted(source: source, global: .auto, picked: nil, installing: false), expected, source)
            XCTAssertEqual(MeetingPolicy.onCallStarted(source: source, global: .ask, picked: .auto, installing: false), .start, "a per-app auto: \(source)")
            XCTAssertEqual(MeetingPolicy.onCallStarted(source: source, global: .auto, picked: .auto, installing: false), .start, "an explicit auto: \(source)")
        }
        XCTAssertTrue(CallDetector.autoStartSources.contains("meet"), "Google Meet records by itself under Record automatically")
    }

    // MARK: #519 icon

    /// Mutation: AppDelegate.applyStatusIcon, `StatusIconImage.make(symbol: style.symbol, red: style.red,` -> `NSImage(systemSymbolName:` -> RED.
    func testTheStatusIconIsAPaintedImageNotATint() throws {
        let a = try source("OxSayDictation/AppDelegate.swift")
        let icon = try XCTUnwrap(body(a, of: "private func applyStatusIcon() {"))
        XCTAssertTrue(icon.contains("StatusIconImage.make(symbol: style.symbol, red: style.red,"))
        XCTAssertFalse(a.contains("contentTintColor"), "the menu bar ignores the tint of a template image")
    }

    // MARK: #520 drag + collapse

    func testThePlateIsMovableAndRemembersWhereItWasLeft() throws {
        let b = try badge()
        XCTAssertTrue(b.contains("panel.isMovableByWindowBackground = true"))
        XCTAssertTrue(b.contains("NSWindow.didMoveNotification"))
        XCTAssertTrue(b.contains("BadgePositions.save(display:"))
        XCTAssertTrue(b.contains("BadgePositions.load("))
        XCTAssertTrue(b.contains("saved: BadgePositions.load(defaults)"))
    }

    /// Mutation: MeetingBadge.showRecording, delete the collapse button -> RED.
    func testTheRecordingPlateCollapsesToAPillThatStaysOnScreen() throws {
        let b = try badge()
        XCTAssertTrue(b.contains("L10nKey.badgeCollapse.text"))
        XCTAssertTrue(b.contains("PlateCollapse.presentation(isRecording:"))
        let toggle = try XCTUnwrap(body(b, of: "func setCollapsed(_ collapsed: Bool) {"))
        XCTAssertFalse(toggle.contains("orderOut"), "collapsing never takes the panel off the screen")
    }
}
