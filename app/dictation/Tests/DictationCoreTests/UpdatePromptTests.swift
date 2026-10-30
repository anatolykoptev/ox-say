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
}
