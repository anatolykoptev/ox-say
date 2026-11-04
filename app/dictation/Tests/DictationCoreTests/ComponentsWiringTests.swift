import Foundation
import XCTest
@testable import DictationCore

/// The window component kit's wiring, read as text (the shim compiles DictationCore only): no
/// hand-built stand-ins for the macOS-14 system views in MainWindowUI — the trailing panel is the
/// system `.inspector`, an empty page is `ContentUnavailableView` — and every icon-only button
/// labelled. Each test names the mutation that must turn it red.
final class ComponentsWiringTests: XCTestCase {
    /// …/app/dictation/Tests/DictationCoreTests/<this file> → Sources/MainWindowUI.
    private var mainWindowUI: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MainWindowUI")
    }

    /// A tripwire (not a proof) against an unlabeled icon button and a hand-built panel or empty
    /// state: within 6 lines of any `Button` in MainWindowUI, an `Image(systemName:` must be
    /// accompanied by `accessibilityLabel` or `IconButton`.
    /// Mutation: add `Button { } label: { Image(systemName: "gear") }` to DictationPage.swift -> RED.
    /// Mutation: add `SidePanel(isOpen: $x) { }` or `EmptyState(symbol: "x", title: "y", message: "z") { }` to any page -> RED.
    func testNoIconOnlyButtonOutsideIconButton() throws {
        for url in try FileManager.default.contentsOfDirectory(at: mainWindowUI, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" && url.lastPathComponent != "IconButton.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("SidePanel("), "\(url.lastPathComponent): use the system .inspector(isPresented:)")
            XCTAssertFalse(text.contains("EmptyState("), "\(url.lastPathComponent): use ContentUnavailableView")
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

    /// The meeting detail is the system inspector: its slide and Reduce Motion are the system's,
    /// and the toolbar toggle is the system's `sidebar.trailing`.
    /// Mutation: MeetingsPage.swift, `.inspector(` back to a hand-built column -> RED on the first check.
    /// Mutation: the toggle's `sidebar.trailing` symbol changed or dropped -> RED on the second.
    func testMeetingDetailIsTheSystemInspector() throws {
        let text = try String(contentsOf: mainWindowUI.appendingPathComponent("MeetingsPage.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains(".inspector(isPresented:"))
        XCTAssertTrue(text.contains("sidebar.trailing"))
    }
}
