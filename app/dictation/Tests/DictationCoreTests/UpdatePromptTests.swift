import XCTest
@testable import DictationCore

final class UpdatePromptTests: XCTestCase {
    private let page = URL(string: "https://github.com/x/y/releases/tag/v0.1.21")!

    private func release(_ tag: String, body: String = "") -> Result<(tag: String, url: URL?, body: String), UpdateError> {
        .success((tag, page, body))
    }

    func testSameVersionIsUpToDate() {
        XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.20")), .upToDate(version: "0.1.20"))
    }

    func testOlderRemoteIsUpToDate() {
        XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.19")), .upToDate(version: "0.1.20"))
    }

    func testNewerRemoteIsAvailableWithNotesAndURL() {
        let prompt = UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.21", body: "## Fixes\n- **paste** works"))
        XCTAssertEqual(prompt, .available(remote: "v0.1.21", local: "0.1.20", notes: "Fixes\n• paste works", url: page))
    }

    /// #372.3: a dev build carries version 0.0.0 (build.sh), older than every release; offering the latest release to it
    /// would be a "downgrade" for a build made from newer code. No prompt for it, whatever GitHub answered.
    /// Mutation: UpdatePrompt.make, delete the `isDevelopmentBuild(local)` guard -> RED.
    func testADevBuildIsNeverOfferedARelease() {
        XCTAssertEqual(UpdatePrompt.make(local: "0.0.0", fetch: release("v0.1.21")), .developmentBuild(version: "0.0.0"))
        XCTAssertEqual(UpdatePrompt.make(local: "0.0.0", fetch: .failure(.http(403))), .developmentBuild(version: "0.0.0"),
                       "nothing to check, so a failed check is not shown either")
        guard case .available = UpdatePrompt.make(local: "0.0.1", fetch: release("v0.1.21")) else {
            return XCTFail("a real (if very old) release is still offered the update")
        }
    }

    /// Mutation: UpdateChecker.isDevelopmentBuild, `== [0, 0, 0]` -> `!= [0, 0, 0]` -> RED.
    func testOnlyVersionZeroIsADevBuild() {
        XCTAssertTrue(UpdateChecker.isDevelopmentBuild("0.0.0"))
        XCTAssertTrue(UpdateChecker.isDevelopmentBuild("v0.0.0"))
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild("0.0.1"))
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild("0.1.0"))
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild("1.0.0"))
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild(""), "an unreadable version is not a dev build")
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild("garbage"))
    }

    /// The background check offers a dev build nothing: no row, no notice, and it counts as an answered check.
    /// Mutation: UpdatePrompt.make, delete the `isDevelopmentBuild(local)` guard -> RED (the dev build is offered v0.1.21).
    func testTheBackgroundCheckOffersADevBuildNothing() {
        var state = AutoUpdateState()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(AutoUpdateSchedule.apply(fetch: release("v0.1.21"), local: "0.0.0", now: now, state: &state), .clear)
        XCTAssertEqual(state.lastCheck, now)
        XCTAssertNil(state.lastNotifiedVersion)
    }

    func testEveryUpdateErrorIsAFailureCarryingItsReason() {
        for error in [UpdateError.unreachable("offline"), .http(403), .http(503), .badResponse] {
            XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: .failure(error), text: ShippedStrings.localizer("en")),
                           .failed(reason: error.message(text: ShippedStrings.localizer("en"))), "\(error)")
        }
    }

    func testNotesReduceMarkdownToPlainText() {
        let md = "## What's new\r\n\r\n* **Fast** paste, see [the docs](https://x.test/d)\r\n- `fix` ([#128](https://x.test/128))\r\n\r\n\r\n\r\n<!-- hidden -->tail"
        XCTAssertEqual(UpdatePrompt.releaseNotesText(md, limit: 500),
                       "What's new\n\n• Fast paste, see the docs\n• fix (#128)\n\ntail")
    }

    func testNotesEmptyBodyIsEmpty() {
        XCTAssertEqual(UpdatePrompt.releaseNotesText("", limit: 10), "")
        XCTAssertEqual(UpdatePrompt.releaseNotesText("  \n\n ", limit: 10), "")
    }

    func testNotesAreCutAtTheLimitWithAnEllipsis() {
        let cut = UpdatePrompt.releaseNotesText(String(repeating: "a", count: 50), limit: 20)
        XCTAssertEqual(cut.count, 20, "the ellipsis counts toward the limit")
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(UpdatePrompt.releaseNotesText("short", limit: 20), "short", "text within the limit is untouched")
    }

    func testAvailableNotesHonourTheLimit() {
        let long = String(repeating: "word ", count: 1000)
        guard case .available(_, _, let notes, _) = UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.21", body: long)) else {
            return XCTFail("expected .available")
        }
        XCTAssertLessThanOrEqual(notes.count, UpdatePrompt.notesLimit)
        XCTAssertTrue(notes.hasSuffix("…"))
    }

    // #494: a release that publishes a macOS floor above this Mac's is not offered.
    /// Mutation: UpdatePrompt.make, delete the `ReleaseFloor.isBelow` check -> RED (`.available` comes back).
    func testAReleaseAboveThisMacsMacOSIsUnsupportedNotOffered() {
        let body = "## Fixes\n- paste works\n\n<!-- ox-say-min-macos: 14.4 -->"
        XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.21", body: body), host: "14.2"),
                       .unsupported(remote: "v0.1.21", local: "0.1.20", floor: "14.4", host: "14.2"))
        XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.21", body: body), host: "14.4.1"),
                       .available(remote: "v0.1.21", local: "0.1.20", notes: "Fixes\n• paste works", url: page),
                       "at or above the floor: offered, and the hidden marker is not in the notes")
        XCTAssertEqual(UpdatePrompt.make(local: "0.1.21", fetch: release("v0.1.21", body: body), host: "13.0"),
                       .upToDate(version: "0.1.21"), "no newer release: the floor is not mentioned")
    }

    /// Fail open: nothing readable as a floor means the update is offered as before.
    func testAMissingOrUnreadableFloorOffersTheUpdate() {
        for body in ["", "no marker", "<!-- ox-say-min-macos: -->", "<!-- ox-say-min-macos: abc -->",
                     "<!-- ox-say-min-macos: 14..2 -->", "<!-- ox-say-min-macos 14.4 -->"] {
            guard case .available = UpdatePrompt.make(local: "0.1.20", fetch: release("v0.1.21", body: body), host: "13.0") else {
                return XCTFail("body \(body.debugDescription) must not block the update")
            }
        }
        XCTAssertFalse(ReleaseFloor.isBelow(host: "garbage", floor: "14.2"))
        XCTAssertFalse(ReleaseFloor.isBelow(host: "14.2", floor: "x"))
    }

    /// The compare is numeric per component. Mutation: ReleaseFloor.isBelow compares the strings -> RED ("14.10").
    func testTheFloorCompareIsNumericPerComponent() {
        XCTAssertFalse(ReleaseFloor.isBelow(host: "14.10", floor: "14.2"))
        XCTAssertTrue(ReleaseFloor.isBelow(host: "14.2", floor: "14.10"))
        XCTAssertFalse(ReleaseFloor.isBelow(host: "15", floor: "14.9.9"))
        XCTAssertFalse(ReleaseFloor.isBelow(host: "14.2", floor: "14.2.0"), "a missing component is 0")
        XCTAssertTrue(ReleaseFloor.isBelow(host: "14.2", floor: "14.2.1"))
        XCTAssertTrue(ReleaseFloor.isBelow(host: "13.6.7", floor: "14.2"))
        XCTAssertEqual(ReleaseFloor.minimum(inBody: "x\n<!--  ox-say-min-macos:  14.2.1  -->\ny"), "14.2.1")
    }

    func testTheUnsupportedAlertReadsRightInBothLanguages() {
        let prompt = UpdatePrompt.unsupported(remote: "v0.2.0", local: "0.1.33", floor: "14.4", host: "14.2")
        XCTAssertEqual(UpdateDialogs.prompt(prompt, text: ShippedStrings.localizer("en")),
                       UpdateDialog(title: "OxSay v0.2.0 needs a newer macOS",
                                    text: "It needs macOS 14.4 or later; this Mac has macOS 14.2. OxSay stays on v0.1.33 here.", buttons: ["OK"]))
        XCTAssertEqual(UpdateDialogs.prompt(prompt, text: ShippedStrings.localizer("ru")),
                       UpdateDialog(title: "Для OxSay v0.2.0 нужна более новая macOS",
                                    text: "Нужна macOS 14.4 или новее, а на этом Mac — macOS 14.2. Здесь OxSay остаётся на v0.1.33.", buttons: ["OK"]))
    }
}
