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
        XCTAssertEqual(app.components(separatedBy: "installUpdate(tag:").count - 1, 5, "four install call sites and the declaration")
        XCTAssertEqual(app.components(separatedBy: "kind: .update)").count - 1, 3, "repair, the prompt and the manual check")
        XCTAssertTrue(app.contains("installUpdate(tag: UpdateInstaller.tag(forVersion: target), kind: .update)"))
        XCTAssertTrue(app.contains("installUpdate(tag: remote, kind: .update)"))
        XCTAssertTrue(app.contains("installUpdate(tag: tag, kind: .update)"))
        XCTAssertTrue(app.contains("installStudioVoice: { [unowned self] in self.installStudioVoice() }"), "the menu reaches the studio install")
        let menu = try source("OxSayDictation/StudioController.swift")
        XCTAssertTrue(menu.contains("case .installStudioVoice: host.installStudioVoice()"))
    }

    /// #175: the document read marks the menu row busy and puts up the pill for exactly as long as it runs, on every way out
    /// (a `defer`), and takes down only its own pill (by task id).
    /// Mutation: StudioController.readScript, delete `readingDocument = false` from the defer -> RED (the menu row stays
    /// disabled after a read); or `host.pill(Self.readingPillTask, nil)` -> RED (the pill never comes down).
    func testTheDocumentReadCleansUpOnEveryWayOut() throws {
        let controller = try source("OxSayDictation/StudioController.swift")
        let read = try body(controller, of: "private func readScript(_ file: URL) async -> String? {")
        let deferAt = try XCTUnwrap(read.range(of: "defer {"))
        let tail = String(read[deferAt.lowerBound...])
        XCTAssertTrue(read.contains("readingDocument = true"))
        XCTAssertTrue(read.contains("host.pill(Self.readingPillTask, L10nKey.studioReadingPill.text)"))
        let flagAt = try XCTUnwrap(read.range(of: "readingDocument = true"))
        XCTAssertLessThan(flagAt.lowerBound, deferAt.lowerBound)
        let doAt = try XCTUnwrap(tail.range(of: "do {"))
        let cleanup = String(tail.prefix(upTo: doAt.lowerBound))
        XCTAssertTrue(cleanup.contains("readingDocument = false"))
        XCTAssertTrue(cleanup.contains("host.pill(Self.readingPillTask, nil)"))
        XCTAssertTrue(controller.contains("static let readingPillTask = \"reading-document\""))
    }

    /// #175: the pill of one task comes down through its slot, which finishes the overlay only while it is still that
    /// task's pill (a dictation overlay up meanwhile is left alone, TaskPillsTests / PillOwnershipTests).
    /// Mutation: AppDelegate.studioHost, route `pill` with no text straight to `overlay.finish()` -> RED.
    func testAStudioPillIsTakenDownThroughItsSlotNotByFinishingTheOverlay() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let host = try body(app, of: "private func studioHost() -> StudioHost {")
        XCTAssertTrue(host.contains("self.endStudioPill(task: task)"))
        XCTAssertFalse(host.contains("overlay.finish()"))
        let end = try body(app, of: "private func endStudioPill(task: String) {")
        XCTAssertTrue(end.contains("studioPills.end(task: task, current: overlay.owner, dictation: controller.state)"))
        XCTAssertTrue(end.contains("endPill(&slot)"))
        XCTAssertFalse(end.contains("overlay.finish()"))
    }

    /// #175: a start the daemon refuses reopens the review with the person's draft; the document's first cleaning is
    /// only the first draft. ⌘Return starts from inside the editor.
    /// Mutation: StudioController.newVoiceover, start from `first.script` instead of `draft.script` -> RED;
    /// ReviewSheet, delete `keyEquivalentModifierMask = .command` -> RED.
    func testTheReviewRetriesWithTheDraftAndStartsOnCommandReturn() throws {
        let controller = try source("OxSayDictation/StudioController.swift")
        let flow = try body(controller, of: "private func newVoiceover() {")
        XCTAssertTrue(flow.contains("await ReviewRetry.run(first, review: { ReviewSheet(draft: $0, voiceNames: choices.names).run() }"))
        XCTAssertTrue(flow.contains("client.startVoiceover(script: draft.script, title: draft.title, voice: draft.voice, format: draft.format)"))
        XCTAssertFalse(flow.contains("script: first.script"), "a refused start must not fall back to the first cleaning")
        XCTAssertTrue(flow.contains("guard let self, let script = await self.readScript(file) else { return }"))
        let sheet = try source("OxSayDictation/ReviewSheet.swift")
        XCTAssertTrue(sheet.contains("startButton.keyEquivalent = \"\\r\""))
        XCTAssertTrue(sheet.contains("startButton.keyEquivalentModifierMask = .command"))
        XCTAssertTrue(sheet.contains("static let startKeyHint = \"⌘Return\""))
    }
}
