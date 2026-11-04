import Foundation
import XCTest
@testable import DictationCore

/// The window component kit's wiring, read as text (the shim compiles DictationCore only): no
/// hand-built stand-ins for the macOS-14 system views in MainWindowUI — an empty page is
/// `ContentUnavailableView` — and every icon-only button labelled. Each test names the mutation that must turn it red.
final class ComponentsWiringTests: XCTestCase {
    /// …/app/dictation/Tests/DictationCoreTests/<this file> → Sources/MainWindowUI.
    private var mainWindowUI: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MainWindowUI")
    }

    /// A tripwire (not a proof) against an unlabeled icon button and a hand-built empty
    /// state (comment lines are ignored, so a comment can neither trip nor satisfy the check): within 6 lines of any `Button` in MainWindowUI, an `Image(systemName:` must be
    /// accompanied by `accessibilityLabel` or `IconButton`.
    /// Mutation: add `Button { } label: { Image(systemName: "gear") }` to DictationPage.swift -> RED.
    /// Mutation: add `EmptyState(symbol: "x", title: "y", message: "z") { }` to any page -> RED.
    func testNoIconOnlyButtonOutsideIconButton() throws {
        for url in try FileManager.default.contentsOfDirectory(at: mainWindowUI, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" && url.lastPathComponent != "IconButton.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = Self.stripComments(text)
            XCTAssertFalse(code.contains("EmptyState("), "\(url.lastPathComponent): use ContentUnavailableView")
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("Button") && !line.contains("buttonStyle") {
                let window = lines[i..<min(i + 6, lines.count)].joined(separator: "\n")
                if window.contains("Image(systemName:") && !window.contains("Text(") && !window.contains("Label(") {
                    XCTAssertTrue(window.contains("accessibilityLabel") || window.contains("IconButton"),
                                "\(url.lastPathComponent):\(i + 1): icon-only Button without a label")
                }
            }
        }
    }

    /// The no-results view fills the pane: without the greedy frame the VStack shrinks to its content
    /// and the search field and privacy line float mid-column.
    /// Mutation: SearchPane.swift, drop `.frame(maxWidth: .infinity, maxHeight: .infinity)` after the no-results
    /// `ContentUnavailableView` -> RED.
    func testSearchNoResultsFillsThePane() throws {
        let text = try String(contentsOf: mainWindowUI.appendingPathComponent("SearchPane.swift"), encoding: .utf8)
        let lines = Self.stripComments(text).components(separatedBy: "\n")
        let at = try XCTUnwrap(lines.firstIndex { $0.contains("ContentUnavailableView") }, "no ContentUnavailableView in SearchPane.swift")
        let window = lines[at..<min(at + 14, lines.count)].joined(separator: "\n")
        XCTAssertTrue(window.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
                      "SearchPane no-results ContentUnavailableView must be followed by the greedy frame")
    }

    /// The old EmptyState carried the greedy frame itself; a bare ContentUnavailableView shrinks to its content,
    /// so a sibling that should sit at the pane's bottom (the privacy line) floats right under it. In every
    /// MainWindowUI file, a ContentUnavailableView that has a `PrivacyLine(` after it in the same stack must be
    /// followed by the greedy frame before that line.
    /// Mutation: MeetingsPage.swift `.empty`, drop the `.frame(maxWidth: .infinity, maxHeight: .infinity)` between
    /// the ContentUnavailableView and `PrivacyLine()` -> RED.
    func testContentUnavailableViewBesideThePrivacyLineFillsTheSpace() throws {
        var checked = 0
        for url in try FileManager.default.contentsOfDirectory(at: mainWindowUI, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" {
            let lines = Self.stripComments(try String(contentsOf: url, encoding: .utf8)).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("ContentUnavailableView") {
                guard let end = lines[i...].prefix(16).firstIndex(where: { $0.contains("PrivacyLine(") }) else { continue }
                checked += 1
                let between = lines[i..<end].joined(separator: "\n")
                XCTAssertTrue(between.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"),
                              "\(url.lastPathComponent):\(i + 1): ContentUnavailableView above PrivacyLine lacks the greedy frame")
            }
        }
        XCTAssertGreaterThan(checked, 0, "no ContentUnavailableView/PrivacyLine pair found: the check has gone vacuous")
    }

    /// Meetings is a list beside a reading pane, drawn by a native split view (native-UI N2b), never a hand-built
    /// `HStack { MeetingList.frame(width: 290); Divider(); detail }`. The window keeps ONE two-column NavigationSplitView:
    /// a three-column shape for Meetings rebuilt the sidebar (width and focus lost) on every switch.
    /// Mutation: MeetingsPage.swift `.list`, put back `HStack(spacing: 0) { MeetingsListColumn(model: model).frame(width: 290)
    /// Divider() MeetingDetailColumn(model: model) }` in place of `MeetingsSplit(model: model)` -> RED.
    func testMeetingsPageHasNoHandBuiltListDetailStack() throws {
        let text = try String(contentsOf: mainWindowUI.appendingPathComponent("MeetingsPage.swift"), encoding: .utf8)
        let lines = Self.stripComments(text).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("HStack") {
            let near = lines[i..<min(i + 8, lines.count)].joined(separator: "\n")
            for word in ["MeetingList(", "MeetingsListColumn(", "MeetingDetailColumn(", "detail"] {
                XCTAssertFalse(near.contains(word), "MeetingsPage.swift:\(i + 1): a hand-built HStack list/detail (\(word))")
            }
        }
        let flat = lines.joined(separator: "\n")
        XCTAssertTrue(flat.contains("case .list:\n            MeetingsSplit(model: model)"), "the list state is the native split")
        XCTAssertTrue(flat.contains("final class MeetingsSplitController: NSSplitViewController"))
        XCTAssertFalse(flat.contains(".frame(width: 290)"))
        // The window itself stays one two-column split: no content: column, no second shape.
        let window = Self.stripComments(try String(contentsOf: mainWindowUI.appendingPathComponent("MainWindowView.swift"), encoding: .utf8))
        XCTAssertEqual(window.components(separatedBy: "NavigationSplitView {").count - 1, 1)
        XCTAssertFalse(window.contains("content:"), "a third column would rebuild the sidebar on each section switch")
    }

    /// The list is 260...420 wide (ideal 290), the meeting never under 300, the divider is kept on the model across a
    /// section switch, and Open Folder / Copy Notes / Delete exist only for a chosen meeting while the list is up.
    /// Mutations: MeetingsPage.swift `listLimits` 260...420 -> 100...900 -> RED; `SelectionToolbar`, drop
    /// `, model.selectedMeeting != nil` (Delete offered with no meeting chosen) -> RED; the alert's
    /// `if let id = model.selectedMeeting` -> `let id = model.selectedMeeting ?? ""` -> RED.
    func testMeetingsSplitLimitsAndSelectionGuards() throws {
        let page = Self.stripComments(try String(contentsOf: mainWindowUI.appendingPathComponent("MeetingsPage.swift"), encoding: .utf8))
        XCTAssertTrue(page.contains("static let listLimits: ClosedRange<CGFloat> = 260...420"))
        XCTAssertTrue(page.contains("static let detailMinimum: CGFloat = 300"))
        XCTAssertTrue(page.contains("model.meetingsListWidth = list.frame.width"))
        XCTAssertTrue(page.contains("if case .list = model.pageState, let d = model.selectedDetail, model.selectedMeeting != nil {"))
        XCTAssertTrue(page.contains("if let id = model.selectedMeeting { model.actions.deleteMeeting(id) }"))
        // The toolbar and the search field stay on the page, outside the AppKit split, so they reach the window.
        XCTAssertTrue(page.contains("SelectionToolbar(model: model, confirmDelete: $confirmDelete)"))
        XCTAssertTrue(page.contains(".searchable(text: $model.queryText"))
    }

    /// Source text without whole-line `//` and `///` comments.
    private static func stripComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
