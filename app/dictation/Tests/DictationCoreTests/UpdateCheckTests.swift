import XCTest
@testable import DictationCore

final class UpdateCheckTests: XCTestCase {
    /// A canned GitHub response; the updater's apiURL is overridden so the
    /// request shape can still be asserted.
    private func fakeSend(data: Data, status: Int = 200) -> UpdateChecker {
        UpdateChecker(apiURL: URL(string: "https://example.test/releases/latest")!, send: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        })
    }

    func testLatestReleaseParsesTheTag() async throws {
        let json = #"{"tag_name":"v0.1.14","html_url":"https://github.com/x/y/releases/tag/v0.1.14"}"#.data(using: .utf8)!
        let (tag, url) = try await fakeSend(data: json).latestRelease()
        XCTAssertEqual(tag, "v0.1.14")
        XCTAssertEqual(url?.absoluteString, "https://github.com/x/y/releases/tag/v0.1.14")
    }

    func testMissingTagIsABadResponse() async {
        do {
            _ = try await fakeSend(data: Data("{}".utf8)).latestRelease()
            XCTFail("expected badResponse")
        } catch {
            XCTAssertEqual(error as? UpdateError, .badResponse)
        }
    }

    func testHttpErrorIsReported() async {
        do {
            _ = try await fakeSend(data: Data(), status: 403).latestRelease()
            XCTFail("expected http(403)")
        } catch {
            XCTAssertEqual(error as? UpdateError, .http(403))
        }
    }

    func testIsNewerComparesNumericTriples() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.1.14", than: "0.1.13"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.99"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.0", than: "0.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.13", than: "0.1.13"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.12", than: "0.1.13"))
    }

    func testIsNewerOnDevAndMalformedTags() {
        // A dev build (0.0.0) always sees a real release as newer.
        XCTAssertTrue(UpdateChecker.isNewer("v0.1.13", than: "0.0.0"))
        // A garbage remote tag sorts oldest — no phantom updates.
        XCTAssertFalse(UpdateChecker.isNewer("latest", than: "0.1.13"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.x.2", than: "0.1.13"))
        // A suffix does not confuse the numeric compare.
        XCTAssertTrue(UpdateChecker.isNewer("v0.1.14-beta1", than: "0.1.13"))
    }
}
