import AppKit
import XCTest
@testable import DictationCore

/// «Hide OxSay overlays from screen sharing and recordings»: every floating panel asks macOS to stay out of captures
/// when the switch is on — and on is the default, so a fresh install hides them, while a stored `false` still wins —
/// a panel that is already up follows a flip at once, and with the switch off a window keeps the system default
/// (`.readOnly`). A panel that misses the setting shows private notes during a screen share and nothing in the app
/// says so, so the guard is here.
/// The panels themselves (`MeetingBadge`, `Overlay`) are in the app target, which the shim does not compile: the tests
/// build real `NSPanel`s through the one function both call, and read the app sources for what calls it.
final class HideFromShareTests: XCTestCase {
    @MainActor
    private func panel() -> NSPanel {
        NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    }

    /// `.none` alone is `Optional.none` inside a generic `XCTAssertEqual` and compares against nil: spell the type.
    private let hidden = NSWindow.SharingType.none

    private func suite() -> UserDefaults { UserDefaults(suiteName: "hide-share-\(UUID().uuidString)")! }

    /// Runs `body` with the spec reading a throwaway defaults suite.
    @MainActor
    private func withSetting(_ on: Bool?, _ body: (UserDefaults) -> Void) {
        let d = suite()
        if let on { DictationSettings.setHideFromShare(on, d) }
        let saved = PlateWindowSpec.defaults
        PlateWindowSpec.defaults = d
        defer { PlateWindowSpec.defaults = saved }
        body(d)
    }

    /// Mutation: MeetingSettingsModel.hideFromShare, `?? true` -> `?? false` -> RED; `return true` -> RED (a stored
    /// `false` must keep the panels shared); a write of the key inside the getter -> RED.
    func testTheSwitchDefaultsToOnAndRoundTrips() {
        let d = suite()
        XCTAssertTrue(DictationSettings.hideFromShare(d), "a missing key must read as on")
        XCTAssertNil(d.object(forKey: DictationSettings.hideFromShareKey), "the getter must not write the default")
        DictationSettings.setHideFromShare(true, d)
        XCTAssertTrue(DictationSettings.hideFromShare(d))
        XCTAssertEqual(d.object(forKey: DictationSettings.hideFromShareKey) as? Bool, true)
        DictationSettings.setHideFromShare(false, d)
        XCTAssertFalse(DictationSettings.hideFromShare(d))
    }

    /// Mutation: PlateWindowSpec.sharingType(hide:), `hide ? .none : .readOnly` -> `.readOnly` for both -> RED.
    func testTheSharingTypeIsNoneWhenHidingAndTheSystemDefaultOtherwise() {
        XCTAssertEqual(PlateWindowSpec.sharingType(hide: true), hidden)
        XCTAssertEqual(PlateWindowSpec.sharingType(hide: false), .readOnly)
    }

    /// Mutation: PlateWindowSpec.apply, delete the `panel.sharingType = ...` line -> RED ("on: ..."); an unset panel is
    /// `.readOnly`, so the stored-off case alone cannot see it.
    @MainActor
    func testApplyHidesEveryPanelUnlessTheUserTurnedItOff() {
        withSetting(true) { _ in
            let plate = panel(), pill = panel()
            PlateWindowSpec.apply(to: plate)
            PlateWindowSpec.apply(to: pill, extra: .ignoresCycle)
            XCTAssertEqual(plate.sharingType, hidden, "on: the plate must ask to stay out of captures")
            XCTAssertEqual(pill.sharingType, hidden, "on: the pill must ask to stay out of captures")
        }
        withSetting(false) { _ in
            let p = panel()
            PlateWindowSpec.apply(to: p)
            XCTAssertEqual(p.sharingType, .readOnly, "stored off: the system default")
        }
        withSetting(nil) { _ in
            let p = panel()
            PlateWindowSpec.apply(to: p)
            XCTAssertEqual(p.sharingType, hidden, "no stored value: the default hides")
        }
    }

    /// The re-show path: a panel hidden from view while the switch flips takes the new value at its next `apply`.
    /// Mutation: MeetingBadge / Overlay re-show, delete `PlateWindowSpec.apply` there -> RED (the wiring test below).
    @MainActor
    func testApplyAtTheNextShowPicksUpAFlipMadeWhileHidden() {
        withSetting(false) { d in
            let p = panel()
            PlateWindowSpec.apply(to: p)
            XCTAssertEqual(p.sharingType, .readOnly)
            DictationSettings.setHideFromShare(true, d)
            PlateWindowSpec.apply(to: p)
            XCTAssertEqual(p.sharingType, hidden)
        }
    }

    /// A flip while panels are on screen reaches them without another `apply`, both ways.
    /// Mutation: PlateWindowSpec.hideFromShareChanged, delete the `for panel in panels.allObjects` loop -> RED.
    @MainActor
    func testAFlipWhileShownIsReappliedToPanelsAlreadyUp() {
        withSetting(false) { d in
            let plate = panel(), pill = panel()
            PlateWindowSpec.apply(to: plate)
            PlateWindowSpec.apply(to: pill, extra: .ignoresCycle)
            DictationSettings.setHideFromShare(true, d)
            PlateWindowSpec.hideFromShareChanged()
            XCTAssertEqual(plate.sharingType, hidden, "flip on: plate")
            XCTAssertEqual(pill.sharingType, hidden, "flip on: pill")
            DictationSettings.setHideFromShare(false, d)
            PlateWindowSpec.hideFromShareChanged()
            XCTAssertEqual(plate.sharingType, .readOnly, "flip off: plate")
            XCTAssertEqual(pill.sharingType, .readOnly, "flip off: pill")
        }
    }

    /// Mutation: PlateWindowSpec.apply, delete `panels.add(panel)` -> RED (the registry is what the live flip walks).
    @MainActor
    func testAPanelThatWentAwayIsNotKeptAlive() {
        withSetting(true) { _ in
            weak var gone: NSPanel?
            autoreleasepool {
                let p = panel()
                PlateWindowSpec.apply(to: p)
                gone = p
            }
            PlateWindowSpec.hideFromShareChanged()
            XCTAssertNil(gone, "the registry holds panels weakly")
        }
    }

    // MARK: the app's side

    private var appSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ relative: String) throws -> String {
        MeetingWiringTests.stripComments(try String(contentsOf: appSources.appendingPathComponent(relative), encoding: .utf8))
    }

    /// Every overlay panel the app builds goes through `PlateWindowSpec.apply` right after it is made, so a new one
    /// cannot skip the setting. The inventory: `MeetingBadge` (the plate and its prompt), `Overlay` (the dictation pill).
    /// `NSWindow(` is the main window only (a normal window, not an overlay). A new panel or window class fails here and
    /// has to be classified on purpose.
    /// Mutation: MeetingBadge.init or Overlay.init, delete `PlateWindowSpec.apply(...)` after `NSPanel(` -> RED.
    func testEveryOverlayPanelIsBuiltThroughThePlateWindowSpec() throws {
        let dir = appSources.appendingPathComponent("OxSayDictation")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        var panels: [String] = [], windows: [String] = []
        for file in files {
            let text = try source("OxSayDictation/\(file)")
            XCTAssertNil(text.range(of: "class\\s+\\w+\\s*:\\s*NSPanel", options: .regularExpression), "\(file): a NSPanel subclass must build through PlateWindowSpec.apply and be listed here")
            var rest = Substring(text)
            while let r = rest.range(of: "NSPanel(contentRect") {
                panels.append(file)
                let tail = rest[r.upperBound...].prefix(400)
                XCTAssertTrue(tail.contains("PlateWindowSpec.apply(to: panel"), "\(file): a NSPanel is built without PlateWindowSpec.apply")
                rest = rest[r.upperBound...]
            }
            if text.contains("NSWindow(") { windows.append(file) }
        }
        XCTAssertEqual(panels, ["MeetingBadge.swift", "Overlay.swift"], "the overlay panels changed: classify the new one")
        XCTAssertEqual(windows, ["MainWindow.swift"], "a new NSWindow: is it an overlay? Then build it through PlateWindowSpec.apply")
    }

    /// The panels DictationCore builds itself (the cue card): every `NSPanel` subclass there applies the spec in its
    /// initializer. The inventory is classified on purpose, like the app's above.
    /// Mutation: CueCardPanel.init, delete `PlateWindowSpec.apply(to: self)` -> RED.
    func testEveryCorePanelSubclassAppliesThePlateWindowSpec() throws {
        let dir = appSources.appendingPathComponent("DictationCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        var panels: [String] = []
        for file in files {
            let text = try source("DictationCore/\(file)")
            guard let r = text.range(of: "class\\s+\\w+\\s*:\\s*NSPanel", options: .regularExpression) else { continue }
            panels.append(file)
            XCTAssertTrue(text[r.upperBound...].prefix(800).contains("PlateWindowSpec.apply(to: self)"),
                          "\(file): a NSPanel subclass is built without PlateWindowSpec.apply")
        }
        XCTAssertEqual(panels, ["CueCardPanel.swift"], "the core's overlay panels changed: classify the new one")
    }

    /// The re-show paths keep asserting the spec (and so the setting): the plate's layout and watchdog, the pill's
    /// show and watchdog. Mutation: delete any of the four `PlateWindowSpec.apply` there -> RED.
    func testTheReShowPathsApplyTheSpecAgain() throws {
        let badge = try source("OxSayDictation/MeetingBadge.swift"), overlay = try source("OxSayDictation/Overlay.swift")
        XCTAssertEqual(badge.components(separatedBy: "PlateWindowSpec.apply(to: panel)").count - 1, 3)
        XCTAssertEqual(overlay.components(separatedBy: "PlateWindowSpec.apply(to: panel, extra: .ignoresCycle)").count - 1, 3)
    }

    /// The Settings switch stores through `DictationSettings`, then re-applies to the panels on screen; the page shows
    /// the stored value and the toggle is on the page, with its one-line best-effort hint.
    /// Mutation: MainWindowSource.dictationActions, drop `PlateWindowSpec.hideFromShareChanged()` -> RED; replace
    /// `DictationSettings.setHideFromShare(on, self.host.defaults)` with a direct key write -> RED;
    /// `hideOverlaysFromShare = DictationSettings.hideFromShare(d)` -> `= false` -> RED.
    func testTheSettingsSwitchIsStoredAppliedAndShown() throws {
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("DictationSettings.setHideFromShare(on, self.host.defaults)"))
        XCTAssertTrue(window.contains("PlateWindowSpec.hideFromShareChanged()"), "panels already on screen must follow the flip")
        XCTAssertTrue(window.contains("model.data.hideOverlaysFromShare = DictationSettings.hideFromShare(d)"), "the page shows the stored value")
        XCTAssertFalse(window.contains("hideOverlaysFromShare\""), "no direct write of the key from the window")
        let page = try source("MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(page.contains("title: L10nKey.settingsHideShare.text, hint: L10nKey.settingsHideShareFooter.text"))
        XCTAssertTrue(page.contains("isOn: model.hideOverlaysFromShare"))
    }

    /// The copy says best effort, in both languages, and never promises hiding.
    func testTheCopyIsBestEffortInBothLanguages() {
        for lang in ["en", "ru"] {
            let text = ShippedStrings.localizer(lang)
            let title = text(.settingsHideShare), hint = text(.settingsHideShareFooter)
            XCTAssertFalse(title.hasPrefix("MISSING"), "\(lang): title missing")
            XCTAssertFalse(hint.hasPrefix("MISSING"), "\(lang): hint missing")
            XCTAssertTrue(hint.contains("15.4"), "\(lang): the hint must name the macOS 15.4 limit")
            XCTAssertTrue(hint.contains(lang == "en" ? "main window" : "Главное окно"), "\(lang): the hint must say what is not covered")
            XCTAssertTrue(hint.contains(lang == "en" ? "default" : "умолчан"), "\(lang): the hint must say the switch is on by default")
            for word in ["invisible", "stealth", "undetectable", "hidden", "невидим", "незаметн", "скрыт"] {
                XCTAssertFalse((title + hint).lowercased().contains(word), "\(lang): promises too much: \(word)")
            }
        }
    }
}
