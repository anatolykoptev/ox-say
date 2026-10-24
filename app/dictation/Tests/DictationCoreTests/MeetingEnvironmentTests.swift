import Foundation
import XCTest
@testable import DictationCore

final class MeetingEnvironmentTests: XCTestCase {
    /// Mutation: OutputRoute.isLikelySpeakers, change the final `return true` to `return false`
    /// -> RED (a USB or HDMI speaker would be taken for headphones and its echo kept).
    func testRoutes() {
        XCTAssertTrue(OutputRoute.isLikelySpeakers(transport: "bltn", dataSource: "ispk", name: "MacBook Pro Speakers"))
        XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "bltn", dataSource: "hdpn", name: "External Headphones"))
        XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "blue", dataSource: nil, name: "Beats"))
        XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "usb ", dataSource: nil, name: "Logitech USB Headset"))
        XCTAssertTrue(OutputRoute.isLikelySpeakers(transport: "usb ", dataSource: nil, name: "Studio Monitors"))
        XCTAssertTrue(OutputRoute.isLikelySpeakers(transport: "hdmi", dataSource: nil, name: "LG TV"))
        XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "bltn", dataSource: nil, name: "Anatoly's AirPods Pro"))
    }

    private struct FakeRunner: AppleScriptRunner {
        var outcome: ScriptOutcome
        func run(_ source: String, timeout: TimeInterval) -> ScriptOutcome { outcome }
    }

    func testBrowserTabOutcomes() {
        XCTAssertEqual(BrowserTabURL.read(bundleID: "com.google.Chrome", runner: FakeRunner(outcome: .value("https://meet.google.com/abc-defg-hij"))),
                       .url("https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(BrowserTabURL.read(bundleID: "x", runner: FakeRunner(outcome: .value(""))), .unreadable)
        XCTAssertEqual(BrowserTabURL.read(bundleID: "x", runner: FakeRunner(outcome: .denied)), .denied)
        XCTAssertEqual(BrowserTabURL.read(bundleID: "x", runner: FakeRunner(outcome: .timedOut)), .unreadable)
    }

    /// The script never launches a browser the user did not start.
    /// Mutation: BrowserTabURL.script, delete the `is running` guard -> RED.
    func testTheScriptChecksTheBrowserIsRunningFirst() {
        let s = BrowserTabURL.script(bundleID: "com.brave.Browser")
        XCTAssertTrue(s.hasPrefix(#"if application id "com.brave.Browser" is running then"#))
        XCTAssertTrue(s.contains("with timeout of 1 second"))
    }
}
