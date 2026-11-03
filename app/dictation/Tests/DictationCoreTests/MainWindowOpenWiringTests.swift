import Foundation
import XCTest
@testable import DictationCore

/// Source pins for the main window's open path (the shim compiles DictationCore only, so the AppKit glue is read as text,
/// without comments). What each decision DOES is tested in DictationCore; these prove the glue calls it from the place that
/// counts. Space behaviour, activation and the title cannot be unit-run: the live check is the owner's.
final class MainWindowOpenWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    @objc func |\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// F1 call site: the window takes the spec's Space behaviour where it is made.
    /// Mutation: MainWindow.makeWindow, delete `window.collectionBehavior = MainWindowSpec.collectionBehavior` -> RED.
    func testTheWindowTakesTheSpaceBehaviourAtItsOneCreationSite() throws {
        let text = try source("OxSayDictation/MainWindow.swift")
        XCTAssertEqual(text.components(separatedBy: "NSWindow(").count - 1, 1, "one creation site")
        let make = try body(text, of: "private func makeWindow(")
        XCTAssertTrue(make.contains("window.collectionBehavior = MainWindowSpec.collectionBehavior"))
        XCTAssertFalse(text.contains("collectionBehavior = ["), "no second, hand-written behaviour")
    }

    /// Open shows the window itself, restores a minimised one and activates with the call that works on macOS 14+.
    /// Mutation: MainWindow.open, delete the `deminiaturize` line or the `orderFrontRegardless` line -> RED.
    func testOpenRestoresRaisesAndActivates() throws {
        let open = try body(try source("OxSayDictation/MainWindow.swift"), of: "func open(route: MainRoute? = nil) {")
        XCTAssertTrue(open.contains("if window.isMiniaturized { window.deminiaturize(nil) }"))
        XCTAssertTrue(open.contains("window.orderFrontRegardless()"))
        let policy = try XCTUnwrap(open.range(of: "NSApp.setActivationPolicy(.regular)"))
        let activate = try XCTUnwrap(open.range(of: "Self.activateApp()"))
        XCTAssertLessThan(policy.lowerBound, activate.lowerBound, "activation follows the policy change")
        let asyncHop = try XCTUnwrap(open.range(of: "DispatchQueue.main.async"))
        XCTAssertLessThan(asyncHop.lowerBound, activate.lowerBound, "activation runs on the next turn, after the policy change settled")
    }

    /// F1 call site: the window takes the keyboard over a full-screen Space. `activate()` is cooperative
    /// and macOS 26 declined it from a non-gesture open, leaving a visible window that is not key;
    /// `activate(ignoringOtherApps:)` activated, with no Space switch (live probe, 3/3).
    /// Mutation: MainWindow.activateApp, `NSApp.activate(ignoringOtherApps: true)` -> `NSApp.activate()` -> RED.
    func testActivationUsesTheStrongCallOnEveryVersion() throws {
        let text = try source("OxSayDictation/MainWindow.swift")
        let activate = try body(text, of: "private static func activateApp() {")
        XCTAssertTrue(activate.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertFalse(activate.contains("#available"), "one call on every version")
        XCTAssertFalse(text.contains("NSApp.activate()"), "the cooperative call is nowhere in the file")
    }

    /// F2 call site: the delayed revert asks the pure decision, and an open tells it.
    /// Mutation: MainWindow.windowWillClose, delete `guard let self, self.revert.shouldRevert(ticket) else { return }` -> RED.
    func testTheDelayedRevertAsksWhetherAnOpenCameInBetween() throws {
        let text = try source("OxSayDictation/MainWindow.swift")
        let close = try body(text, of: "func windowWillClose(_ notification: Notification) {")
        XCTAssertTrue(close.contains("let ticket = revert.windowClosed()"))
        XCTAssertTrue(close.contains("guard let self, self.revert.shouldRevert(ticket) else { return }"))
        let open = try body(text, of: "func open(route: MainRoute? = nil) {")
        XCTAssertTrue(open.contains("revert.windowOpened()"))
    }

    /// F5: only the window view sets a navigation title, and it is the app's, with the section as the subtitle.
    /// Mutation: any MainWindowUI page, add `.navigationTitle(L10nKey.sectionMeetings.text)` -> RED.
    func testNoPageOverridesTheWindowTitle() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MainWindowUI")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        for file in files where file != "MainWindowView.swift" {
            let text = try source("MainWindowUI/\(file)")
            XCTAssertFalse(text.contains("navigationTitle("), "\(file) sets the window title")
        }
        let view = try source("MainWindowUI/MainWindowView.swift")
        XCTAssertEqual(view.components(separatedBy: "navigationTitle(").count - 1, 1)
        XCTAssertTrue(view.contains(".navigationTitle(MainWindowSpec.windowTitleKey.text)"))
        XCTAssertTrue(view.contains(".navigationSubtitle(MainWindowSpec.subtitleKey(for: model.section).text)"))
    }

    /// Reopen (a second launch, a Dock click) opens the same window.
    /// Mutation: AppDelegate.applicationShouldHandleReopen, delete `mainWindow.open()` -> RED.
    func testReopenOpensTheWindow() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let reopen = try body(app, of: "func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {")
        XCTAssertTrue(reopen.contains("mainWindow.open()"))
        XCTAssertTrue(reopen.contains("return false"), "handled: AppKit's own reopen must not run over it")
    }

    /// F4 call site: the decision is read before the launch migration writes its marker, from the event, and acted on.
    /// Mutation: AppDelegate.applicationDidFinishLaunching, `atLogin:` argument -> `false` -> RED.
    func testTheFirstLaunchDecisionReadsTheLoginEventBeforeAnythingIsWritten() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let launch = try body(app, of: "func applicationDidFinishLaunching(_ notification: Notification) {")
        let claim = try XCTUnwrap(launch.range(of: "FirstLaunch.claim(UserDefaults.standard, atLogin: launchedAtLogin())"))
        let migrate = try XCTUnwrap(launch.range(of: "CallPolicy.migrateStaleAutoPicks"))
        XCTAssertLessThan(claim.lowerBound, migrate.lowerBound, "the migration marker is itself evidence of a prior run")
        XCTAssertTrue(launch.contains("if openWindowOnFirstLaunch { mainWindow.open() }"))
        let probe = try body(app, of: "private func launchedAtLogin() -> Bool {")
        XCTAssertTrue(probe.contains("NSAppleEventManager.shared().currentAppleEvent"))
        XCTAssertTrue(probe.contains("FirstLaunch.isLoginLaunch(eventID: event?.eventID"))
        XCTAssertTrue(probe.contains("forKeyword: FirstLaunch.propDataKeyword"))
    }

    /// The key the old copies wrote must be the one FirstLaunch looks for.
    func testThePriorRunKeysAreTheOnesTheAppWrites() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("private let keyInUseKey = \"dictationKeyInUse\""))
        XCTAssertTrue(app.contains("private let speakKeyInUseKey = \"speakKeyInUse\""))
        XCTAssertEqual(Set(FirstLaunch.priorRunKeys), ["dictationKeyInUse", "speakKeyInUse", CallPolicy.pickMigrationKey])
    }

    /// The section is saved on every change, so a quit with the window open still restores it; the next open restores it.
    /// Mutation: MainWindowSource.init, `model.section = restored.section` -> `model.section = .meetings` -> RED.
    func testTheWindowRestoresAndSavesItsRoute() throws {
        let text = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(text.contains("let restored = WindowRestoration.load(host.defaults, advanced: model.advanced)"))
        XCTAssertTrue(text.contains("model.section = restored.section"))
        XCTAssertTrue(text.contains("model.selectedMeeting = restored.meetingID"))
        XCTAssertTrue(text.contains("WindowRestoration.save(MainRoute(section: section, meetingID: meeting), to: defaults)"))
    }

    /// F1 call site: flipping the switch reinstalls the menu bar, or ⌘N points at the old order.
    /// Mutation: MainWindow.swift:"MainMenuBar.install(appDelegateTarget: appDelegate, for: .regular, advanced:" in the advanced sink, delete -> RED.
    func testTheAdvancedSwitchReinstallsTheMenu() throws {
        let text = try source("OxSayDictation/MainWindow.swift")
        let sink = try body(text, of: "private func observeAdvanced(")
        XCTAssertTrue(sink.contains("MainMenuBar.install(appDelegateTarget: appDelegate, for: .regular, advanced: on)"))
        // No condition to invert: the source has one creation site, and that site attaches the observer.
        XCTAssertEqual(text.components(separatedBy: "MainWindowSource(host:").count - 1, 1, "one creation site")
        let make = try body(text, of: "private func makeSource(")
        XCTAssertTrue(make.contains("MainWindowSource(host:"))
        XCTAssertTrue(make.contains("observeAdvanced(source)"))
        XCTAssertEqual(text.components(separatedBy: "observeAdvanced(").count - 1, 2, "the definition and the one call")
        let open = try body(text, of: "func open(route: MainRoute? = nil) {")
        XCTAssertTrue(open.contains("self.source ?? makeSource(appDelegate)"))
        XCTAssertFalse(open.contains("observeAdvanced("), "open does not decide whether to observe")
    }

    /// The window model and the route start on the same section, from one source.
    /// Mutation: MainWindowModel.init, `section: MainSection = MainWindowSpec.firstRunSection` -> `.meetings` -> RED.
    func testTheModelStartsOnTheFirstRunSection() throws {
        let model = try source("MainWindowUI/MainWindowModel.swift")
        XCTAssertTrue(model.contains("section: MainSection = MainWindowSpec.firstRunSection"))
        XCTAssertEqual(MainRoute().section, MainWindowSpec.firstRunSection)
    }

    /// F0 call site: every install passes the live switch, or the first close (applyPolicy) resets ⌘ order to the
    /// simple one while Advanced is on. The source exists before the first install, so `open` can read its state.
    /// Mutation: MainWindow.swift:"MainMenuBar.install(appDelegateTarget: appDelegate, for: policy" in applyPolicy loses `advanced:` -> RED.
    func testEveryMenuInstallPassesTheAdvancedState() throws {
        let text = try source("OxSayDictation/MainWindow.swift")
        let installs = text.components(separatedBy: "MainMenuBar.install(").dropFirst()
        XCTAssertEqual(installs.count, 3, "open, applyPolicy and the advanced sink")
        for call in installs {
            let line = String(call.prefix { $0 != "\n" })
            XCTAssertTrue(line.contains("advanced:"), "install without the switch state: \(line)")
        }
        let policy = try body(text, of: "private func applyPolicy() {")
        XCTAssertTrue(policy.contains("MainMenuBar.install(appDelegateTarget: appDelegate, for: policy, advanced:"))
        let open = try body(text, of: "func open(route: MainRoute? = nil) {")
        let made = try XCTUnwrap(open.range(of: "makeSource("))
        let install = try XCTUnwrap(open.range(of: "MainMenuBar.install("))
        XCTAssertLessThan(made.lowerBound, install.lowerBound, "the source is made before the menu is installed")
    }

    /// The switch and the stored section are read from the same defaults before the route is restored, and a flip is saved
    /// and moves the window off Models.
    /// Mutation: MainWindowSource.init, delete `AdvancedMode.set(on, in: defaults)` -> RED.
    func testTheSourceLoadsAndSavesTheSwitchAndMovesOffModels() throws {
        let text = try source("OxSayDictation/MainWindowSource.swift")
        let initBody = try body(text, of: "init(host: MainWindowHost) {")
        let read = try XCTUnwrap(initBody.range(of: "model.advanced = AdvancedMode.isOn(host.defaults)"))
        let restore = try XCTUnwrap(initBody.range(of: "WindowRestoration.load(host.defaults, advanced: model.advanced)"))
        XCTAssertLessThan(read.lowerBound, restore.lowerBound, "the switch is read before the route is restored")
        XCTAssertTrue(initBody.contains("AdvancedMode.set(on, in: defaults)"))
        XCTAssertTrue(initBody.contains("model.section = AdvancedMode.section(after: on, current: model.section)"))
        let apply = try body(text, of: "func apply(_ route: MainRoute) {")
        XCTAssertTrue(apply.contains("route.resolved(visible: MainWindowSpec.sections(advanced: model.advanced))"))
    }

    /// The menu keys reach the window through one route.
    /// Mutation: MainMenuBar.bind, the `.showSection` case aimed at nothing -> RED.
    /// Mutation: AppDelegate.showSectionFromMenu, `mainWindow.show(` back to `mainWindow.open(route:` -> RED.
    func testSectionKeysOpenTheWindowOnThatSection() throws {
        let bar = try source("OxSayDictation/MainMenu.swift")
        XCTAssertTrue(bar.contains("case .showSection(let section):"))
        XCTAssertTrue(bar.contains("item.action = #selector(AppDelegate.showSectionFromMenu(_:))"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        let show = try body(app, of: "@objc func showSectionFromMenu(_ sender: NSMenuItem) {")
        XCTAssertTrue(show.contains("mainWindow.show(MainRoute(section: section, meetingID: nil))"))
    }

    /// A section key on a window that is already in front changes only the section: the key check comes before
    /// the `open` call and the key branch applies the route and returns, so a key window never reaches `open`.
    /// Mutation: MainWindow.show, drop the `isKeyWindow` check so it always applies and returns -> RED.
    func testASectionKeyOnTheKeyWindowOnlyChangesTheSection() throws {
        let show = try body(try source("OxSayDictation/MainWindow.swift"), of: "func show(_ route: MainRoute) {")
        let key = try XCTUnwrap(show.range(of: "window?.isKeyWindow == true"))
        let apply = try XCTUnwrap(show.range(of: "source.apply(route)"))
        let open = try XCTUnwrap(show.range(of: "open(route: route)"))
        XCTAssertLessThan(key.lowerBound, open.lowerBound, "the key check guards the open")
        XCTAssertLessThan(apply.lowerBound, open.lowerBound, "the key branch applies, it does not open")
        XCTAssertTrue(show[apply.upperBound..<open.lowerBound].contains("return"),
                      "the key branch returns, so a key window never reaches open")
    }

    /// A restored meeting survives an empty first list: the check stays armed until a list with rows has judged it.
    /// Mutation: MainWindowSource.refresh, `restoredMeetingUnchecked = list.isEmpty` -> `restoredMeetingUnchecked = false` -> RED.
    func testAnEmptyListLeavesTheRestoredMeetingUnchecked() throws {
        let refresh = try body(try source("OxSayDictation/MainWindowSource.swift"), of: "func refresh() {")
        XCTAssertTrue(refresh.contains("restoredMeetingUnchecked = list.isEmpty"))
        XCTAssertTrue(refresh.contains(".pruned(knownMeetingIDs: list.map(\\.id)).meetingID"))
    }

    /// F1 call site: a restored selection was never read — the `onChange` does not fire for an initial value — so the
    /// read decision, not the presence of a detail, sends it to `loadDetail`; a failed read still waits for Retry.
    /// Mutation: MainWindowSource.refreshSelectedDetail, the `DetailRead.needed` guard back to
    /// `guard let shown = model.data.details[id]?.info` -> RED.
    func testARestoredMeetingAsksTheReadDecisionAndIsLoaded() throws {
        let refresh = try body(try source("OxSayDictation/MainWindowSource.swift"), of: "private func refreshSelectedDetail() {")
        XCTAssertTrue(refresh.contains("DetailRead.needed(row: row, shown: model.data.details[id]?.info, failed: model.data.detailError[id] != nil, loading: model.data.detailLoading.contains(id))"))
        XCTAssertTrue(refresh.contains("loadDetail(id)"))
        XCTAssertFalse(refresh.contains("guard let shown"), "a meeting whose detail was never read is read, not skipped")
    }

    /// Text-only pin (the observer lives in AppKit glue the shim does not compile); the decision is `ActivationRefreshTests`.
    /// Mutation: MainWindowSource.windowClosed, delete `removeObserver(activeObserver)` -> RED (a closed window must cost nothing).
    func testActivationRefreshIsRegisteredOnOpenAndRemovedOnClose() throws {
        let text = try source("OxSayDictation/MainWindowSource.swift")
        let opened = try body(text, of: "func windowOpened() {")
        let closed = try body(text, of: "func windowClosed() {")
        let observer = try body(text, of: "private func observeActivation() {")
        let detail = try body(text, of: "private func refreshSelectedDetail() {")
        let refresh = try body(text, of: "func refresh() {")
        XCTAssertTrue(opened.contains("observeActivation()"))
        XCTAssertTrue(observer.contains("didBecomeActiveNotification"))
        XCTAssertTrue(closed.contains("removeObserver(activeObserver)"))
        XCTAssertTrue(detail.contains("loading: model.data.detailLoading.contains(id)"))
        // The activation path goes through the pure decision and the gated refresh, never a read of its own.
        XCTAssertTrue(observer.contains("ActivationRefresh.shouldRefresh(windowOpen: self.windowOpen, visible: self.visible"))
        XCTAssertTrue(observer.contains("self.refresh()"))
        // Text-only pins: the stamp precedes the first read; the pass runs local sections, then the permissions, then the list.
        let permissions = try body(text, of: "private func readPermissions() {")
        let stamp = try XCTUnwrap(permissions.range(of: "lastPermissionRead = ProcessInfo.processInfo.systemUptime"))
        let firstRead = try XCTUnwrap(permissions.range(of: "applyPermissions()"))
        XCTAssertTrue(stamp.lowerBound < firstRead.lowerBound, "stamped before the first read")
        XCTAssertTrue(observer.contains("now: ProcessInfo.processInfo.systemUptime"))
        let local = try XCTUnwrap(refresh.range(of: "loadSimpleSections()"))
        let perm = try XCTUnwrap(refresh.range(of: "readPermissions()"), "pass reads the permissions")
        let list = try XCTUnwrap(refresh.range(of: "await service.list()"))
        let settings = try XCTUnwrap(refresh.range(of: "await reloadSettingsAsync()"))
        XCTAssertTrue(local.lowerBound < perm.lowerBound, "local sections first")
        XCTAssertTrue(perm.lowerBound < list.lowerBound && perm.lowerBound < settings.lowerBound,
                      "a slow daemon must not delay the permission rows")
        // Text-only pins: the pass never waits for the notification read (a stuck one must not hold the gate), and
        // one read is in flight at most, cleared when it lands.
        XCTAssertFalse(refresh.contains("notificationRead"), "no join in refresh")
        XCTAssertFalse(refresh.contains("await readPermissions()"))
        XCTAssertFalse(refresh.contains("notifications.value"), "the pass awaits no notification task")
        XCTAssertTrue(permissions.contains("guard notificationRead == nil else { return }"))
        XCTAssertTrue(permissions.contains("notificationRead = Task { @MainActor in"))
        XCTAssertTrue(permissions.contains("notificationRead = nil"))
        XCTAssertFalse(closed.contains("notificationRead"), "closing the window leaves the read alone")
        // Text-only: the glue keeps the answer optional (nil until the first read), so the core leaves the row out.
        XCTAssertTrue(text.contains("private var notificationAuth: PermissionAuth?"))
        let apply = try body(text, of: "private func applyPermissions() {")
        XCTAssertTrue(apply.contains("notifications: notificationAuth)"))
    }
}
