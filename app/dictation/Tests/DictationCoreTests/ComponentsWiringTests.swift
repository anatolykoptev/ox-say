import Foundation
import XCTest
@testable import DictationCore

/// The window component kit's wiring, read as text (the shim compiles DictationCore only): no
/// macOS-14-only views in MainWindowUI, every icon-only button labelled, and the side panel's
/// animation routed through MotionPolicy. Each test names the mutation that must turn it red.
final class ComponentsWiringTests: XCTestCase {
    /// …/app/dictation/Tests/DictationCoreTests/<this file> → Sources/MainWindowUI.
    private var mainWindowUI: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MainWindowUI")
    }

    /// A tripwire (not a proof) against an unlabeled icon button: within 6 lines of any `Button` in
    /// MainWindowUI, an `Image(systemName:` must be accompanied by `accessibilityLabel` or `IconButton`.
    /// Mutation: add `Button { } label: { Image(systemName: "gear") }` to DictationPage.swift -> RED.
    func testNoIconOnlyButtonOutsideIconButton() throws {
        for url in try FileManager.default.contentsOfDirectory(at: mainWindowUI, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" && url.lastPathComponent != "IconButton.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(".inspector("), "\(url.lastPathComponent): .inspector is macOS 14; use SidePanel")
            XCTAssertFalse(text.contains("ContentUnavailableView"), "\(url.lastPathComponent): macOS 14 only; use EmptyState")
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

    /// The panel's slide is gated on Reduce Motion like every animation in the window.
    /// Mutation: SidePanel.swift, `MotionPolicy.animationSeconds(0.2, reduceMotion: reduceMotion)` -> `0.2` -> RED.
    func testSidePanelAnimatesThroughMotionPolicy() throws {
        let text = try String(contentsOf: mainWindowUI.appendingPathComponent("SidePanel.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("MotionPolicy.animationSeconds"))
    }
}
