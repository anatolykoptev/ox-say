import Foundation
import XCTest
@testable import DictationCore

/// The Studio menu's AppKit glue cannot run under the shim; what it must DO is decided in DictationCore (StudioPickup,
/// UpdateInstaller.command) and tested there. These read the glue as text, without comments, and pin the two decisions
/// that no behavioural test sees: the launch pickup retry and the install kind each caller passes.
final class StudioWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MeetingWiringTests.stripComments(try String(contentsOf: root.appendingPathComponent("Sources/\(relative)"), encoding: .utf8))
    }

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    @objc private func |\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    /// Any answer from the daemon starts the pickup; none does not.
    /// Mutation: StudioPickup.lookOnStatus, return `false` -> RED.
    func testAnyAnswerStartsThePickupAndNoAnswerDoesNot() {
        XCTAssertFalse(StudioPickup.lookOnStatus(nil))
        XCTAssertTrue(StudioPickup.lookOnStatus(DaemonStatus(version: "0.1.30", studioAvailable: false)))
        XCTAssertTrue(StudioPickup.lookOnStatus(DaemonStatus(version: "0.1.30", studioAvailable: true)))
    }

    /// Dropping the call disables the launch pickup retry with every behavioural test green.
    /// Mutation: StudioController.statusChanged, delete `if StudioPickup.lookOnStatus(new) { follower.serviceAnswered() }`
    /// (or restore `if new != nil`-less code) -> RED.
    func testStatusChangedAsksTheFollowerToLookForARunningVoiceover() throws {
        let controller = try source("OxSayDictation/StudioController.swift")
        let changed = try body(controller, of: "func statusChanged(_ new: DaemonStatus?) {")
        XCTAssertTrue(changed.contains("if StudioPickup.lookOnStatus(new) { follower.serviceAnswered() }"))
        let answered = try XCTUnwrap(changed.range(of: "follower.serviceAnswered()"))
        let rendered = try XCTUnwrap(changed.range(of: "render()"))
        XCTAssertLessThan(answered.lowerBound, rendered.lowerBound)
    }

    /// Swapping one `kind:` leaves every test green and the studio model never downloads (or an update installs the
    /// studio switch). The studio voice install passes `.studioVoice`; the three update paths pass `.update`.
    /// Mutation: AppDelegate.installStudioVoice, `kind: .studioVoice` -> `kind: .update` -> RED; or any update call to `.studioVoice` -> RED.
    func testEveryInstallPassesItsOwnKind() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let studio = try body(app, of: "private func installStudioVoice() {")
        XCTAssertTrue(studio.contains("installUpdate(tag: UpdateInstaller.tag(forVersion: AboutPanel.appVersion), kind: .studioVoice)"))
        XCTAssertEqual(app.components(separatedBy: "kind: .studioVoice").count - 1, 1, "only the studio voice install")
        XCTAssertEqual(app.components(separatedBy: "installUpdate(tag:").count - 1, 4, "four install call sites")
        XCTAssertEqual(app.components(separatedBy: "kind: .update)").count - 1, 3, "repair, the prompt and the manual check")
        XCTAssertTrue(app.contains("installUpdate(tag: UpdateInstaller.tag(forVersion: target), kind: .update)"))
        XCTAssertTrue(app.contains("installUpdate(tag: remote, kind: .update)"))
        XCTAssertTrue(app.contains("installUpdate(tag: tag, kind: .update)"))
        XCTAssertTrue(app.contains("installStudioVoice: { [unowned self] in self.installStudioVoice() }"), "the menu reaches the studio install")
        let menu = try source("OxSayDictation/StudioController.swift")
        XCTAssertTrue(menu.contains("case .installStudioVoice: host.installStudioVoice()"))
    }
}
