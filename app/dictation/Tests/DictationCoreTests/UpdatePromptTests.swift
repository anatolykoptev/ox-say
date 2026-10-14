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

    func testEveryUpdateErrorIsAFailureCarryingItsReason() {
        for error in [UpdateError.unreachable("offline"), .http(403), .http(503), .badResponse] {
            XCTAssertEqual(UpdatePrompt.make(local: "0.1.20", fetch: .failure(error)),
                           .failed(reason: String(describing: error)), "\(error)")
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
