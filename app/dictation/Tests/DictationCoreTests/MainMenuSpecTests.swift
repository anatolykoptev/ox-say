import XCTest
@testable import DictationCore

final class MainMenuSpecTests: XCTestCase {
    private func rows(of menu: L10nKey) -> [MainMenuRow] {
        MainMenu.spec().first { $0.title == menu }!.rows
    }

    private func item(_ selector: String, in rows: [MainMenuRow]) -> MainMenuItem? {
        for row in rows {
            if case .item(let item) = row, item.selector == selector { return item }
        }
        return nil
    }

    func testTheBarHasAppEditAndWindowMenusInOrder() {
        XCTAssertEqual(MainMenu.spec().map(\.title), [.menuApp, .menuEdit, .menuWindow])
    }

    /// Without an Edit menu a posted Cmd+V is matched by no item and never
    /// reaches a text field — for a menu-bar app this is the difference between
    /// dictation landing in our window and going nowhere.
    func testTheEditMenuCarriesTheStandardEditingItems() {
        let rows = rows(of: .menuEdit)
        let expectations: [(selector: String, key: String, shift: Bool)] = [
            ("undo:", "z", false), ("redo:", "z", true),
            ("cut:", "x", false), ("copy:", "c", false), ("paste:", "v", false),
            ("selectAll:", "a", false),
        ]
        for expected in expectations {
            guard let found = item(expected.selector, in: rows) else {
                XCTFail("the Edit menu has no \(expected.selector) item")
                continue
            }
            XCTAssertEqual(found.keyEquivalent, expected.key, expected.selector)
            XCTAssertEqual(found.shift, expected.shift, expected.selector)
        }
    }

    func testTheAppMenuQuitsAndHidesAndRoutesAboutToTheDelegate() {
        let rows = rows(of: .menuApp)
        XCTAssertEqual(item("terminate:", in: rows)?.keyEquivalent, "q")
        XCTAssertEqual(item("hide:", in: rows)?.keyEquivalent, "h")
        let about = item("showAbout:", in: rows)
        XCTAssertEqual(about?.target, .appDelegate, "About must reach the delegate, which knows the service version")
    }

    func testTheWindowMenuMinimizesAndCloses() {
        let rows = rows(of: .menuWindow)
        XCTAssertEqual(item("performMiniaturize:", in: rows)?.keyEquivalent, "m")
        XCTAssertEqual(item("performClose:", in: rows)?.keyEquivalent, "w")
    }

    /// Every row's title is a known localization key, so the W4 key-set check
    /// covers the menu without a hand-maintained list.
    func testEveryTitleIsAKnownLocalizationKey() {
        for spec in MainMenu.spec() {
            XCTAssertTrue(L10nKey.allCases.contains(spec.title))
            for row in spec.rows {
                guard case .item(let item) = row else { continue }
                XCTAssertTrue(L10nKey.allCases.contains(item.title), "\(item.selector) has a title outside L10nKey")
            }
        }
    }
}
