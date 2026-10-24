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

    /// Bluetooth is not headphones: speakers and conference speakerphones are "blue" too.
    /// Mutation: OutputRoute.isLikelySpeakers, add `if transport == "blue" || transport == "blea" { return false }`
    /// as its first line -> RED.
    func testBluetoothSpeakersAreSpeakers() {
        for name in ["JBL Flip 6", "Jabra Speak 750", "Poly Sync 20", "Anker PowerConf S3", "HomePod", "Bose SoundLink Flex", "Beats Pill", "My Car"] {
            XCTAssertTrue(OutputRoute.isLikelySpeakers(transport: "blue", dataSource: nil, name: name), name)
            XCTAssertTrue(OutputRoute.isLikelySpeakers(transport: "blea", dataSource: nil, name: name), name)
        }
        for name in ["AirPods Pro", "WH-1000XM5", "WF-1000XM4", "Galaxy Buds", "Pixel Buds Pro", "Bose QC45", "Sony Earbuds", "Anatoly\u{2019}s AirPods", "Jabra Headset", "Beats Studio3"] {
            XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "blue", dataSource: nil, name: name), name)
            XCTAssertFalse(OutputRoute.isLikelySpeakers(transport: "blea", dataSource: nil, name: name), name)
        }
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
        let s = BrowserTabURL.script(bundleID: "com.brave.Browser") ?? ""
        XCTAssertTrue(s.hasPrefix(#"if application id "com.brave.Browser" is running then"#))
        XCTAssertTrue(s.contains("with timeout of 1 second"))
    }

    /// The bundle id is spliced into AppleScript source: anything that is not an id is refused.
    /// Mutation: BrowserTabURL.script, delete the `guard bundleID.range(…)` line -> RED.
    func testTheScriptRefusesAnythingButABundleID() {
        XCTAssertNotNil(BrowserTabURL.script(bundleID: "company.thebrowser.Browser"))
        for bad in ["", "com.x\" to quit\n", "a b", "x;y", "com.x\nfoo", "é"] {
            XCTAssertNil(BrowserTabURL.script(bundleID: bad), bad)
            XCTAssertEqual(BrowserTabURL.read(bundleID: bad, runner: FakeRunner(outcome: .value("https://x"))), .unreadable)
        }
    }
}
