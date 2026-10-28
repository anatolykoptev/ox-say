import XCTest
@testable import DictationCore

final class MainMenuSpecTests: XCTestCase {
    private func rows(of menu: L10nKey, for policy: WindowPolicy.Policy = .regular) -> [MainMenuRow] {
        MainMenuSpec.menu(for: policy).first { $0.title == menu }!.rows
    }

    private func item(_ selector: String, in rows: [MainMenuRow]) -> MainMenuItem? {
        for row in rows {
            if case .item(let item) = row, item.action == .standard(selector) { return item }
        }
        return nil
    }

    private func standardSelectors(in specs: [MainMenuSpec]) -> Set<String> {
        var names = Set<String>()
        for spec in specs {
            for row in spec.rows {
                if case .item(let item) = row, case .standard(let name) = item.action {
                    names.insert(name)
                }
            }
        }
        return names
    }

    func testTheBarHasAppEditAndWindowMenusInOrder() {
        XCTAssertEqual(MainMenuSpec.menu(for: .regular).map(\.title), [.menuApp, .menuEdit, .menuWindow])
    }

    /// Under .accessory nothing on screen says the app is active — no Dock
    /// icon, no menu bar. Only the Edit menu is bound, so ⌘Z/⌘C/⌘V/⌘A still
    /// reach a modal's editor (the review sheet) while ⌘Q, ⌘H and ⌘W aimed at
    /// "dismiss this" cannot quit or hide the daemon.
    func testAccessoryInstallsOnlyTheEditMenu() {
        let specs = MainMenuSpec.menu(for: .accessory)
        XCTAssertEqual(specs.map(\.title), [.menuEdit])
        let names = standardSelectors(in: specs)
        XCTAssertTrue(names.contains("paste:"), "the Edit menu must survive under .accessory")
        for regularOnly in ["terminate:", "hide:", "performClose:"] {
            XCTAssertFalse(names.contains(regularOnly),
                           "\(regularOnly) must stay unbound while nothing shows the app is active")
        }
    }

    func testRegularBindsTheAppAndWindowKeys() {
        let names = standardSelectors(in: MainMenuSpec.menu(for: .regular))
        for expected in ["terminate:", "hide:", "performClose:", "performMiniaturize:", "paste:"] {
            XCTAssertTrue(names.contains(expected), "the regular bar must bind \(expected)")
        }
    }

    /// Without an Edit menu a posted Cmd+V is matched by no item and never
    /// reaches a text field — for a menu-bar app this is the difference between
    /// dictation landing in our window and going nowhere. It must hold under
    /// both policies: the review sheet runs while the app is still .accessory.
    func testTheEditMenuCarriesTheStandardEditingItems() {
        for policy in [WindowPolicy.Policy.regular, .accessory] {
            let rows = rows(of: .menuEdit, for: policy)
            let expectations: [(selector: String, key: String, shift: Bool)] = [
                ("undo:", "z", false), ("redo:", "z", true),
                ("cut:", "x", false), ("copy:", "c", false), ("paste:", "v", false),
                ("selectAll:", "a", false),
            ]
            for expected in expectations {
                guard let found = item(expected.selector, in: rows) else {
                    XCTFail("the Edit menu has no \(expected.selector) item under \(policy)")
                    continue
                }
                XCTAssertEqual(found.keyEquivalent, expected.key, expected.selector)
                XCTAssertEqual(found.shift, expected.shift, expected.selector)
            }
        }
    }

    func testTheAppMenuQuitsAndHides() {
        let rows = rows(of: .menuApp)
        XCTAssertEqual(item("terminate:", in: rows)?.keyEquivalent, "q")
        XCTAssertEqual(item("hide:", in: rows)?.keyEquivalent, "h")
    }

    /// About carries a typed action, not a selector string: the AppKit layer
    /// binds it to #selector(AppDelegate.showAbout), so a name that resolves
    /// to nothing cannot hide here again.
    func testTheAboutItemCarriesTheTypedAboutAction() {
        for row in rows(of: .menuApp) {
            guard case .item(let item) = row, item.title == .menuAppAbout else { continue }
            XCTAssertEqual(item.action, .about)
            return
        }
        XCTFail("the App menu has no About item")
    }

    func testTheWindowMenuMinimizesAndCloses() {
        let rows = rows(of: .menuWindow)
        XCTAssertEqual(item("performMiniaturize:", in: rows)?.keyEquivalent, "m")
        XCTAssertEqual(item("performClose:", in: rows)?.keyEquivalent, "w")
    }

    /// Every row fires either a typed app action or a standard AppKit
    /// selector — never neither, never both — and every standard name is one
    /// AppKit actually answers, so a typo fails here instead of shipping a
    /// dead item. A new action kind breaks this switch and must be classified.
    func testEveryItemHasExactlyOneActionFromAKnownSet() {
        for policy in [WindowPolicy.Policy.regular, .accessory] {
            for spec in MainMenuSpec.menu(for: policy) {
                for row in spec.rows {
                    guard case .item(let item) = row else { continue }
                    switch item.action {
                    case .about:
                        break
                    case .standard(let name):
                        XCTAssertTrue(StandardMenuSelector.names.contains(name),
                                      "\(name) is not a standard AppKit selector")
                    }
                }
            }
        }
    }

    /// #187 — the allowlist names only selectors AppKit answers in this app.
    /// `close:` is not a responder selector (the action is `performClose:`) and
    /// nothing here implements `orderFrontPreferencesWindow:`: a row naming
    /// either would render dead while the membership test above stayed green.
    /// Mutation: re-add either name to StandardMenuSelector.names
    /// (MainMenuSpec.swift) -> RED.
    func testTheAllowlistHoldsNoSelectorNothingAnswers() {
        XCTAssertFalse(StandardMenuSelector.names.contains("close:"))
        XCTAssertFalse(StandardMenuSelector.names.contains("orderFrontPreferencesWindow:"))
        XCTAssertTrue(StandardMenuSelector.names.contains("performClose:"))
    }

    /// Every row's title is a known localization key, so the W4 key-set check
    /// covers the menu without a hand-maintained list.
    func testEveryTitleIsAKnownLocalizationKey() {
        for policy in [WindowPolicy.Policy.regular, .accessory] {
            for spec in MainMenuSpec.menu(for: policy) {
                XCTAssertTrue(L10nKey.allCases.contains(spec.title))
                for row in spec.rows {
                    guard case .item(let item) = row else { continue }
                    XCTAssertTrue(L10nKey.allCases.contains(item.title), "\(item.title) is outside L10nKey")
                }
            }
        }
    }
}
