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

    /// Source text without whole-line `//` and `///` comments.
    private static func stripComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
