import AppKit
import XCTest
@testable import DictationCore

/// The cue card («Шпаргалка»): the real panel is born under `PlateWindowSpec` like the plate and the pill, is see-through
/// and never takes focus, its controls are AppKit buttons wired to the one controller, the text updates in place,
/// and the text, the text size and the frame per display round-trip. Each test names the mutation that must make it
/// RED. No test puts a window on the screen: the controller is handed a recorder instead of `orderFrontRegardless`.
final class CueCardTests: XCTestCase {
    /// `.none` alone is `Optional.none` inside a generic XCTAssertEqual: spell the type.
    private let hidden = NSWindow.SharingType.none

    private func suite() -> UserDefaults { UserDefaults(suiteName: "cuecard-\(UUID().uuidString)")! }

    @MainActor
    private func withHideFromShare(_ on: Bool, _ body: (UserDefaults) -> Void) {
        let d = suite()
        DictationSettings.setHideFromShare(on, d)
        let saved = PlateWindowSpec.defaults
        PlateWindowSpec.defaults = d
        defer { PlateWindowSpec.defaults = saved }
        body(d)
    }

    /// A controller whose show and hide are recorded, never drawn.
    @MainActor
    private final class Harness {
        var presented = 0
        var dismissed = 0
        let defaults: UserDefaults
        private(set) var card: CueCard!

        init(_ defaults: UserDefaults) {
            self.defaults = defaults
            card = CueCard(defaults: defaults, present: { [unowned self] _ in self.presented += 1 },
                           dismiss: { [unowned self] _ in self.dismissed += 1 })
        }
    }

    @MainActor
    private func fire(_ button: NSButton) {
        guard let target = button.target as? NSObject, let action = button.action else {
            XCTFail("\(button.toolTip ?? button.title): no target or action")
            return
        }
        target.perform(action, with: button)
    }

    // MARK: the panel

    /// F1 — the card is born under the panel spec: the production constructor gives it the overlays' level, the
    /// all-Spaces collection behaviour and the hide-from-share flag; a flip while it exists reaches it at once.
    /// Mutation: CueCardPanel.init (CueCardPanel.swift), delete `PlateWindowSpec.apply(to: self)` -> RED.
    @MainActor
    func testTheCardIsBornUnderThePanelSpec() {
        withHideFromShare(true) { _ in
            let panel = CueCardPanel()
            XCTAssertEqual(panel.level, PlateWindowSpec.level, "the card must float where the plate does")
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications),
                          "the card must reach another app's full-screen Space")
            XCTAssertEqual(panel.sharingType, hidden, "hide-from-share on: the card asks to stay out of captures")
            XCTAssertFalse(panel.hidesOnDeactivate, "the card stays up while the call app is frontmost")
        }
        withHideFromShare(false) { d in
            let panel = CueCardPanel()
            XCTAssertEqual(panel.level, PlateWindowSpec.level)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
            XCTAssertEqual(panel.sharingType, .readOnly, "hide-from-share off: the system default")
            DictationSettings.setHideFromShare(true, d)
            PlateWindowSpec.hideFromShareChanged()
            XCTAssertEqual(panel.sharingType, hidden, "a flip while the card exists changes it without a re-show")
        }
    }

    /// F2 — showing the card never takes focus: a non-activating panel that cannot become key or main.
    /// Mutation: CueCardPanel.init, remove `.nonactivatingPanel` from the style mask -> RED.
    @MainActor
    func testTheCardNeverTakesFocus() {
        let panel = CueCardPanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "a key-capable card would steal the call app's focus")
        XCTAssertTrue(panel.styleMask.contains(.borderless), "no title bar that can never look active")
        XCTAssertTrue(panel.styleMask.contains(.resizable), "edge resize")
        XCTAssertFalse(panel.canBecomeKey, "the card must never become the key window")
        XCTAssertFalse(panel.canBecomeMain, "the card must never become the main window")
        XCTAssertTrue(panel.isMovableByWindowBackground, "dragged by any part that is not a button")
    }

    /// F3 — the card is see-through: a clear, non-opaque window over the plate's material, behind-window blended, in
    /// the pill's dark appearance. The material is the bottom layer and the header and the body are its siblings, so
    /// the background setting can fade it without fading the text.
    /// Mutation: CueCardPanel.init, `isOpaque = false` -> `isOpaque = true` -> RED.
    @MainActor
    func testTheCardIsSeeThrough() throws {
        let panel = CueCardPanel()
        XCTAssertFalse(panel.isOpaque, "an opaque window hides what is behind the card")
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.appearance?.name, .vibrantDark, "always dark, like the pill")
        let content = try XCTUnwrap(panel.contentView as? CueCardView)
        let material = try XCTUnwrap(content.subviews.first as? NSVisualEffectView, "the material is the bottom layer")
        XCTAssertTrue(material === content.material)
        XCTAssertEqual(material.material, .hudWindow)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertEqual(material.state, .active)
        XCTAssertTrue(material.subviews.isEmpty, "the text and the buttons are not inside the material")
        XCTAssertTrue(content.scroll.superview === content, "the body is a sibling of the material")
    }

    // MARK: the controls

    /// F4 — every header button and the empty state's button is an AppKit button wired to the controller, and the views
    /// under the pointer take the first click while the panel is not key.
    /// Mutations: CueCardView.acceptsFirstMouse returns false -> RED; CueCard.makePanel, delete
    /// `card.onClose = { [weak self] in self?.hide() }` -> RED.
    @MainActor
    func testEveryControlFiresOnTheFirstClick() throws {
        let h = Harness(suite())
        CueCardStore.setText("notes", h.defaults)
        h.card.show()
        let panel = try XCTUnwrap(h.card.panel)
        let view = panel.card
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "the card's content takes the first click")
        XCTAssertTrue(view.text.acceptsFirstMouse(for: nil), "the body takes the first click (a drag)")
        XCTAssertTrue(view.mouseDownCanMoveWindow && view.text.mouseDownCanMoveWindow, "body and margins drag the card")
        for button in [view.smaller, view.larger, view.collapse, view.close, view.emptyButton] as [NSButton] {
            XCTAssertNotNil(button.target, "\(button.toolTip ?? button.title): no target")
            XCTAssertEqual(button.action, #selector(PlateControls.Action.fire))
            XCTAssertFalse(button.mouseDownCanMoveWindow, "a drag from a button must not move the card")
            XCTAssertTrue(button.acceptsFirstMouse(for: nil), "\(button.toolTip ?? button.title): takes the first click")
        }

        let step = CueCardStore.textStep(h.defaults)
        fire(view.larger)
        XCTAssertEqual(CueCardStore.textStep(h.defaults), step + 1, "larger")
        fire(view.smaller)
        XCTAssertEqual(CueCardStore.textStep(h.defaults), step, "smaller")
        fire(view.collapse)
        XCTAssertTrue(h.card.isCollapsed, "fold")
        fire(view.collapse)
        XCTAssertFalse(h.card.isCollapsed, "unfold")
        fire(view.close)
        XCTAssertFalse(h.card.isShown, "× hides the card")
        XCTAssertEqual(h.dismissed, 1, "× takes the panel off the screen")

        var opened = 0
        h.card.onOpenEditor = { opened += 1 }
        CueCardStore.setText("", h.defaults)
        h.card.show()
        XCTAssertFalse(view.empty.isHidden, "an empty card shows its empty state")
        fire(view.emptyButton)
        XCTAssertEqual(opened, 1, "«Заполнить в настройках» opens Settings")
        XCTAssertFalse(h.card.isShown, "and hides the card")
    }

    /// F5 — the toggle the hotkey and the menu row share: shown, hidden, shown; × then the toggle shows again.
    /// Mutation: CueCard.toggle, make it always `show()` -> RED.
    @MainActor
    func testTheToggleShowsHidesAndShowsAgain() throws {
        let h = Harness(suite())
        XCTAssertFalse(h.card.isShown)
        h.card.toggle()
        XCTAssertTrue(h.card.isShown, "the first press shows the card")
        h.card.toggle()
        XCTAssertFalse(h.card.isShown, "the second press hides it")
        h.card.toggle()
        XCTAssertTrue(h.card.isShown, "the third press shows it again")
        fire(try XCTUnwrap(h.card.panel).card.close)
        XCTAssertFalse(h.card.isShown, "× hides it")
        h.card.toggle()
        XCTAssertTrue(h.card.isShown, "after ×, one press shows the card again")
        XCTAssertEqual(h.presented, 3)
        XCTAssertEqual(h.dismissed, 2)
    }

    /// Header buttons: 24 pt targets that do not overlap, each with a tooltip and an accessibility label; smaller and
    /// larger go grey at the ends of the range.
    /// Mutation: CueCardView.makeHeader, delete the 24 pt width constraint -> RED.
    @MainActor
    func testTheHeaderButtonsAreLargeEnoughAndNamed() throws {
        let h = Harness(suite())
        CueCardStore.setText("notes", h.defaults)
        h.card.show()
        let view = try XCTUnwrap(h.card.panel).card
        view.layoutSubtreeIfNeeded()
        let buttons = [view.smaller, view.larger, view.collapse, view.close] as [NSButton]
        let header = try XCTUnwrap(view.close.superview)
        XCTAssertEqual(header.frame.width, view.bounds.width, "the header spans the card")
        XCTAssertEqual(view.close.frame.maxX, header.bounds.width - 8, accuracy: 0.5, "× sits at the right edge")
        XCTAssertLessThan(view.title.frame.maxX, view.smaller.frame.minX, "the title is left of the buttons")
        for (i, b) in buttons.enumerated() {
            XCTAssertGreaterThanOrEqual(b.frame.width, 24, "\(b.toolTip ?? "")")
            XCTAssertGreaterThanOrEqual(b.frame.height, 24, "\(b.toolTip ?? "")")
            XCTAssertFalse((b.toolTip ?? "").isEmpty)
            XCTAssertFalse((b.accessibilityLabel() ?? "").isEmpty)
            if i > 0 { XCTAssertFalse(b.frame.intersects(buttons[i - 1].frame), "frames overlap") }
        }
        CueCardStore.setTextStep(0, h.defaults)
        h.card.refresh()
        XCTAssertFalse(view.smaller.isEnabled, "no step under 13 pt")
        CueCardStore.setTextStep(3, h.defaults)
        h.card.refresh()
        XCTAssertFalse(view.larger.isEnabled, "no step over 20 pt")
        XCTAssertTrue(view.smaller.isEnabled)
    }

    /// Folding leaves the 28 pt header strip at the same top-left corner; unfolding restores the size and the body's
    /// scroll position, and neither is remembered as the user's frame.
    /// Mutation: CueCardPlacement.collapsed, keep `frame.minY` as the origin -> RED (the top edge moves).
    @MainActor
    func testFoldingKeepsTheTopLeftCornerAndUnfoldingRestores() throws {
        let h = Harness(suite())
        CueCardStore.setText(Array(repeating: "line", count: 200).joined(separator: "\n"), h.defaults)
        h.card.show()
        let panel = try XCTUnwrap(h.card.panel)
        let before = panel.frame
        panel.card.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.card.text.frame.width, panel.card.scroll.contentSize.width, accuracy: 0.5,
                       "the text is as wide as the body")
        XCTAssertGreaterThan(panel.card.scroll.contentSize.width, 200)
        XCTAssertGreaterThan(panel.card.text.frame.height, panel.card.scroll.contentSize.height, "200 lines overflow the body")
        panel.card.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        h.card.setCollapsed(true)
        XCTAssertEqual(panel.frame.height, CueCardPlacement.headerHeight)
        XCTAssertEqual(panel.frame.minX, before.minX)
        XCTAssertEqual(panel.frame.maxY, before.maxY, "the top edge stays put")
        XCTAssertTrue(panel.card.scroll.isHidden, "folded, only the header is left")
        h.card.setCollapsed(false)
        XCTAssertEqual(panel.frame, before)
        XCTAssertEqual(panel.card.scroll.contentView.bounds.origin.y, 100, "the scroll position survives the fold")
        XCTAssertTrue(CueCardFrames.load(h.defaults).isEmpty, "the card's own moves are not the user's frame")
    }

    // MARK: the text

    /// F6 — typing in the Settings editor updates the card in place: 200 updates keep the same content view and text
    /// view, and the card shows the newest text.
    /// Mutation: CueCard.refresh, rebuild `panel.contentView` per call (v1) -> RED.
    @MainActor
    func testTextUpdatesDoNotRebuildTheCard() throws {
        let h = Harness(suite())
        CueCardStore.setText("a", h.defaults)
        h.card.show()
        let panel = try XCTUnwrap(h.card.panel)
        let content = try XCTUnwrap(panel.contentView)
        let text = panel.card.text
        var typed = "a"
        for i in 0..<200 {
            typed += String(i % 10)
            CueCardStore.setText(typed, h.defaults)
            h.card.refresh()
        }
        XCTAssertTrue(panel.contentView === content, "a keystroke must not replace the card's content view")
        XCTAssertTrue(panel.card.text === text, "a keystroke must not replace the body")
        XCTAssertEqual(text.string, typed, "the card shows the newest text")
    }

    /// Two paragraphs, a `#` heading and three `- ` lines show as separate lines in that order; the heading loses its
    /// marker and is semibold; inline bold is bold; a `#tag` is not a heading.
    /// Mutation: CueCardText.render, parse the whole text with the default (full) syntax -> RED (lines run together).
    func testMarkdownKeepsLinesAndBoldsHeadings() throws {
        let source = "First paragraph.\n\nSecond **paragraph**.\n# Plan\n- one\n- two\n- three\n#tag"
        let out = CueCardText.render(source, size: 15)
        XCTAssertEqual(out.string, "First paragraph.\n\nSecond paragraph.\nPlan\n- one\n- two\n- three\n#tag")
        func weight(at text: String) throws -> CGFloat {
            let at = (out.string as NSString).range(of: text).location
            let font = try XCTUnwrap(out.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? CGFloat) ?? 0
        }
        let plan = try weight(at: "Plan"), body = try weight(at: "First"), tag = try weight(at: "#tag")
        XCTAssertGreaterThan(plan, body, "a heading is heavier than the body")
        XCTAssertEqual(tag, body, "#tag is not a heading")
        let strongAt = (out.string as NSString).range(of: "paragraph.\nPlan").location
        let strong = try XCTUnwrap(out.attribute(.font, at: strongAt, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(strong.fontDescriptor.symbolicTraits.contains(.bold), "**bold** is bold")
        XCTAssertNotNil(out.attribute(.shadow, at: 0, effectiveRange: nil), "the text carries its shadow")
    }

    // MARK: the store

    /// F7 — the notes, the text size and the frame per display round-trip: two displays keep their own frames.
    /// Mutation: CueCardFrames.save, drop the `all[displayKey] = ...` write -> RED.
    func testTextStepAndPerDisplayFrameRoundTrip() {
        let d = suite()
        let displayA = "display-uuid-a", displayB = "display-uuid-b"
        let frameA = NSRect(x: 10, y: 20, width: 300, height: 200)
        let frameB = NSRect(x: 400, y: 500, width: 560, height: 400)
        CueCardStore.setText("**facts**\n- 42", d)
        CueCardStore.setTextStep(3, d)
        CueCardFrames.save(frameA, for: displayA, d)
        CueCardFrames.save(frameB, for: displayB, d)
        XCTAssertEqual(CueCardStore.text(d), "**facts**\n- 42")
        XCTAssertEqual(CueCardStore.textStep(d), 3)
        XCTAssertEqual(CueCardFrames.frame(for: displayA, d), frameA, "display A keeps its own frame")
        XCTAssertEqual(CueCardFrames.frame(for: displayB, d), frameB, "display B keeps its own frame")
        let moved = NSRect(x: 1, y: 2, width: 320, height: 220)
        CueCardFrames.save(moved, for: displayA, d)
        XCTAssertEqual(CueCardFrames.frame(for: displayA, d), moved, "a drag re-files the frame")
        XCTAssertEqual(CueCardFrames.frame(for: displayB, d), frameB, "the other display is not disturbed")
    }

    /// The text step defaults to 15 pt and stays inside 13–20 pt.
    /// Mutation: CueCardStore.setTextStep, store `step` unclamped -> RED.
    func testTheTextStepDefaultsAndClamps() {
        let d = suite()
        XCTAssertEqual(CueCardStore.textSizes[CueCardStore.textStep(d)], 15)
        CueCardStore.setTextStep(9, d)
        XCTAssertEqual(CueCardStore.textStep(d), 3)
        CueCardStore.setTextStep(-2, d)
        XCTAssertEqual(CueCardStore.textStep(d), 0)
    }

    /// «Фон шпаргалки»: 40–100 %, full by default; Reduce Transparency draws the material at full strength.
    /// Mutation: CueCardStore.materialAlpha, ignore `reduceTransparency` -> RED.
    func testTheBackgroundDefaultsClampsAndStandsDownForReduceTransparency() {
        let d = suite()
        XCTAssertEqual(CueCardStore.background(d), 1)
        CueCardStore.setBackground(0.1, d)
        XCTAssertEqual(CueCardStore.background(d), 0.4)
        CueCardStore.setBackground(0.7, d)
        XCTAssertEqual(CueCardStore.materialAlpha(stored: CueCardStore.background(d), reduceTransparency: false), 0.7)
        XCTAssertEqual(CueCardStore.materialAlpha(stored: 0.7, reduceTransparency: true), 1)
    }

    /// The background reaches the material only: the text and the buttons stay at full strength.
    /// Mutation: CueCardView.setMaterialAlpha, set `alphaValue` on the card view itself -> RED.
    @MainActor
    func testTheBackgroundFadesOnlyTheMaterial() throws {
        let h = Harness(suite())
        CueCardStore.setText("notes", h.defaults)
        CueCardStore.setBackground(0.5, h.defaults)
        h.card.show()
        let panel = try XCTUnwrap(h.card.panel)
        let view = panel.card
        let expected: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.5
        XCTAssertEqual(view.material.alphaValue, expected, accuracy: 0.001)
        XCTAssertEqual(view.alphaValue, 1)
        XCTAssertEqual(view.scroll.alphaValue, 1)
        XCTAssertEqual(panel.alphaValue, 1, "never the whole window: that fades the text")
    }

    /// The 20,000-character cap is enforced at the store for every writer; the editor's
    /// `cuecard.limit` line is what makes the cut non-silent.
    /// Mutation: CueCardStore.setText, store `text` instead of `cap(text)` -> RED.
    func testTextIsCappedAtTheLimit() {
        let d = suite()
        CueCardStore.setText(String(repeating: "a", count: CueCardStore.textLimit + 500), d)
        XCTAssertEqual(CueCardStore.text(d).count, CueCardStore.textLimit)
    }

    /// «Вставить строку о записи» appends the consent line at the end of the notes.
    /// Mutation: consentAppended, prepend the line instead of appending -> RED.
    func testTheConsentLineAppendsAtTheEnd() {
        XCTAssertEqual(CueCardStore.consentAppended(to: "", line: "L"), "L")
        XCTAssertEqual(CueCardStore.consentAppended(to: "notes", line: "L"), "notes\nL")
        XCTAssertEqual(CueCardStore.consentAppended(to: "notes\n", line: "L"), "notes\nL")
    }

    /// A remembered frame is taken back while it still overlaps the screen; with none, or one dragged nearly off the
    /// screen, the card opens top-centre, 56 pt under the top of the usable area, at 380×260.
    /// Mutation: CueCardPlacement.frame, return `saved` unconditionally -> RED.
    func testTheDefaultPlaceIsTopCentreAndARememberedFrameWins() {
        let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let saved = NSRect(x: 100, y: 100, width: 460, height: 320)
        XCTAssertEqual(CueCardPlacement.frame(saved: saved, on: visible), saved)
        let offscreen = NSRect(x: 5000, y: 100, width: 460, height: 320)
        XCTAssertNotEqual(CueCardPlacement.frame(saved: offscreen, on: visible), offscreen,
                          "a frame off the display falls back to the default")
        let first = CueCardPlacement.frame(saved: nil, on: visible)
        XCTAssertEqual(first.midX, visible.midX, "no saved frame: centred horizontally")
        XCTAssertEqual(first.maxY, visible.maxY - CueCardPlacement.topGap, "under the plate's row")
        XCTAssertEqual(first.size, NSSize(width: 380, height: 260))
        XCTAssertEqual(CueCardPlacement.maxSize(on: visible), NSSize(width: 560, height: 560))
    }

    // MARK: the app's side

    private var appSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ relative: String) throws -> String {
        MeetingWiringTests.stripComments(try String(contentsOf: appSources.appendingPathComponent(relative), encoding: .utf8))
    }

    /// One code path from macOS 14.2 to 26: no availability branch in the card's files.
    /// Mutation: add an `if #available(macOS 26, *)` branch to CueCardPanel.swift -> RED.
    func testTheCardHasOneCodePath() throws {
        for file in ["DictationCore/CueCard.swift", "DictationCore/CueCardPanel.swift", "DictationCore/PlateControls.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("#available"), "\(file): one code path for every supported macOS")
            XCTAssertFalse(text.contains("glassEffect"), "\(file): the plate's material, not a newer one")
        }
    }

    /// The plate and the card make their buttons with the one shared helper, not two copies.
    /// Mutation: give MeetingBadge its own `private func iconButton` again -> RED.
    func testThePlateAndTheCardShareTheButtonHelper() throws {
        let badge = try source("OxSayDictation/MeetingBadge.swift"), card = try source("DictationCore/CueCardPanel.swift")
        XCTAssertFalse(badge.contains("func iconButton("), "the plate must not keep its own copy")
        XCTAssertFalse(badge.contains("func button("), "the plate must not keep its own copy")
        XCTAssertTrue(badge.contains("PlateControls.iconButton("))
        XCTAssertTrue(card.contains("PlateControls.iconButton("))
        XCTAssertTrue(card.contains("PlateControls.button("))
    }

    /// The ⌃⌥K press and the status-menu row both land on `cueCard.toggle()` — the one controller method the toggle test
    /// above covers.
    /// Mutation: registerCueCardKey, point onDown at `show()` instead of `toggleCueCard` -> RED.
    func testTheKeyAndTheMenuRowShareTheToggle() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("action: #selector(toggleCueCard)"), "the menu row calls the toggle")
        XCTAssertTrue(app.contains("self?.toggleCueCard()"), "the key press calls the toggle")
        XCTAssertEqual(app.components(separatedBy: "cueCard.toggle()").count - 1, 1,
                       "one controller method both entry points reach")
        XCTAssertTrue(app.contains("CueCardShortcut.keyCode"), "the registered key is the fixed ⌃⌥K")
        XCTAssertTrue(app.contains("cueCardChanged: { [unowned self] in self.cueCard.refresh() }"),
                      "an edit updates the card in place")
        XCTAssertTrue(app.contains("showCueCard: { [unowned self] in self.cueCard.show() }"),
                      "Settings' Show button shows the same card, never hides it")
    }

    /// The Settings section: the editor is bound to the notes, both buttons and the background slider are wired to
    /// their actions, and the hotkey row shows the key the app registered.
    /// Mutation: SettingsPage.cueCard, drop any of them -> RED on its line.
    func testTheSettingsSectionIsWired() throws {
        let page = try source("MainWindowUI/SettingsPage.swift")
        XCTAssertTrue(page.contains("TextEditor(text: model.cueCardText)"), "the editor edits the card's text")
        XCTAssertTrue(page.contains("model.actions.insertCueConsent()"), "«Вставить строку о записи»")
        XCTAssertTrue(page.contains("model.actions.showCueCard()"), "«Показать шпаргалку»")
        XCTAssertTrue(page.contains("model.data.cueCardKeyTitle"), "the section shows the hotkey")
        XCTAssertTrue(page.contains("Slider(value: model.cueCardBackground, in: CueCardStore.backgroundRange)"), "«Фон шпаргалки»")
        let source = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(source.contains("CueCardStore.setText(text, self.host.defaults)"), "edits persist to the defaults key")
        XCTAssertTrue(source.contains("CueCardStore.consentAppended(to: self.model.data.cueCardText, line: L10nKey.cueCardConsent.text)"),
                      "the notice line is the localized consent string")
        XCTAssertTrue(source.contains("host.showCueCard()"), "the button shows the card")
        XCTAssertTrue(source.contains("CueCardStore.setBackground(value, self.host.defaults)"), "the slider persists")
        XCTAssertTrue(source.contains("model.data.cueCardBackground = CueCardStore.background(d)"), "the page shows the stored value")
    }

    /// The empty card's button opens the main window on the Settings section (where «Шпаргалка» lives).
    /// Mutation: the onOpenEditor wiring, point it at another section -> RED.
    func testTheEmptyCardOpensTheSettingsSection() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("cueCard.onOpenEditor = { [weak self] in self?.mainWindow.show(MainRoute(section: .settings)) }"),
                      "the empty card's button opens the window on Settings")
    }

    /// The card joins the overlays the hide-from-share copy promises: the footer names it in both languages.
    func testTheHideFromShareCopyCoversTheCard() {
        for lang in ["en", "ru"] {
            let text = ShippedStrings.localizer(lang)
            let hint = text(.settingsHideShareFooter)
            XCTAssertTrue(hint.contains(lang == "en" ? "cue card" : "шпаргалку"),
                          "\(lang): the covered overlays list must include the cue card")
        }
    }
}
