import XCTest
@testable import DictationCore

final class DaemonStatusTests: XCTestCase {
    private func decode(_ json: String) -> DaemonStatus? { DaemonStatus.decode(Data(json.utf8)) }

    func testStudioVoiceAvailable() {
        let status = decode(#"{"version":"v0.1.21","voxcpm2":{"available":true,"state":"stopped"},"voices":[]}"#)
        XCTAssertEqual(status, DaemonStatus(version: "v0.1.21", studioAvailable: true, studioReason: nil))
    }

    func testStudioVoiceUnavailableCarriesTheDaemonsReason() {
        let status = decode(#"{"version":"v0.1.21","voxcpm2":{"available":false,"state":"unavailable","reason":"Studio voices need a Mac with Apple Silicon."}}"#)
        XCTAssertEqual(status?.studioAvailable, false)
        XCTAssertEqual(status?.studioReason, "Studio voices need a Mac with Apple Silicon.")
    }

    func testReasonCodeIsDecoded() {
        let status = decode(#"{"voxcpm2":{"available":false,"reason":"x","reason_code":"model_missing"}}"#)
        XCTAssertEqual(status?.studioReasonCode, "model_missing")
        XCTAssertEqual(status?.installWouldHelp, true)
        XCTAssertEqual(decode(#"{"voxcpm2":{"available":false,"reason":"x","reason_code":"unsupported"}}"#)?.installWouldHelp, false)
        XCTAssertNil(decode(#"{"voxcpm2":{"available":false,"reason":"x"}}"#)?.studioReasonCode)
        XCTAssertEqual(decode(#"{"voxcpm2":{"available":false,"reason":"x"}}"#)?.installWouldHelp, false,
                       "a reason with no code: this app cannot tell, so it does not offer 3 GB")
        XCTAssertEqual(decode(#"{"version":"v0.1.10"}"#)?.installWouldHelp, true)
        XCTAssertEqual(decode(#"{"voxcpm2":{"available":true,"reason_code":"model_missing"}}"#)?.installWouldHelp, false)
    }

    func testMissingStudioSectionMeansUnavailable() {
        XCTAssertEqual(decode(#"{"version":"v0.1.10"}"#)?.studioAvailable, false)
        XCTAssertNil(decode(#"{"version":"v0.1.10"}"#)?.studioReason)
    }

    func testMissingOrEmptyVersionIsNil() {
        XCTAssertNil(decode(#"{"voxcpm2":{"available":true}}"#)?.version)
        XCTAssertNil(decode(#"{"version":"","voxcpm2":{"available":true}}"#)?.version)
    }

    func testNotAJsonObjectIsNil() {
        XCTAssertNil(decode("<html>nope</html>"))
        XCTAssertNil(decode("[1,2]"))
    }

    func testStatusClientReadsTheStatusRoute() async throws {
        var seen: URLRequest?
        let client = StudioClient(send: { request in
            seen = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"version":"v0.1.21","voxcpm2":{"available":true}}"#.utf8), response)
        })
        let status = try await client.status()
        XCTAssertEqual(seen?.url?.path, "/status")
        XCTAssertEqual(seen?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(status.version, "v0.1.21")
    }

    func testStatusClientReportsAnUnreachableDaemon() async {
        let client = StudioClient(send: { _ in throw URLError(.cannotConnectToHost) })
        do {
            _ = try await client.status()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StudioError, .daemonUnreachable)
        }
    }

    // MARK: footer

    func testFooterIsTheBundleVersionOnly() {
        XCTAssertEqual(MenuFooter.text(appVersion: "0.1.21"), "Version 0.1.21")
        XCTAssertEqual(MenuFooter.text(appVersion: "v0.1.21"), "Version 0.1.21")
    }

    // MARK: About

    func testAboutLinesNameTheServiceAndBothPermissions() {
        let lines = AboutInfo.lines(serviceVersion: "v0.1.21", microphoneAllowed: true, accessibilityAllowed: false)
        XCTAssertEqual(lines, [AboutInfo.tagline, "Service: v0.1.21", "Microphone: allowed", "Accessibility: not allowed"])
    }

    func testAboutSaysWhenTheServiceCannotBeReached() {
        let lines = AboutInfo.lines(serviceVersion: nil, microphoneAllowed: false, accessibilityAllowed: true)
        XCTAssertEqual(lines[1], "Service: not reachable")
        XCTAssertEqual(lines[2], "Microphone: not allowed")
    }
}
