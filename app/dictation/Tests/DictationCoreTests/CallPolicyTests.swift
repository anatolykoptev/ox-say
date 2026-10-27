import Foundation
import XCTest
@testable import DictationCore

/// Per-app record / ask / don't record, on top of CallDetector's sources.
final class CallPolicyTests: XCTestCase {
    private func suite() -> UserDefaults {
        let d = UserDefaults(suiteName: "mw2-callpolicy-\(UUID().uuidString)")!
        return d
    }

    /// Today's behaviour is the default: the work-call sources record by themselves, everything else asks.
    /// Mutation: CallPolicy.defaultMode, `.ask` -> `.auto` for the else branch (or drop the autoStartSources test) -> RED.
    func testDefaultsAreTodaysBehaviour() {
        let d = suite()
        for source in ["zoom", "teams", "webex", "meet", "oxpulse"] {
            XCTAssertEqual(CallPolicy.mode(for: source, d), .auto, source)
        }
        for source in ["discord", "whatsapp", "telegram", "slack", "facetime"] {
            XCTAssertEqual(CallPolicy.mode(for: source, d), .ask, source)
        }
        XCTAssertEqual(Set(CallDetector.autoStartSources.filter { CallPolicy.sources.contains($0) }),
                       Set(CallPolicy.sources.filter { CallPolicy.mode(for: $0, d) == .auto }),
                       "the defaults are derived from the detector, not retyped")
    }

    func testAnAppNobodyKnowsAsksFirst() {
        XCTAssertEqual(CallPolicy.mode(for: "newcallapp", suite()), .ask)
    }

    func testAPickIsStoredPerAppAndOnlyForThatApp() {
        let d = suite()
        CallPolicy.setMode(.never, for: "discord", d)
        CallPolicy.setMode(.ask, for: "zoom", d)
        XCTAssertEqual(CallPolicy.mode(for: "discord", d), .never)
        XCTAssertEqual(CallPolicy.mode(for: "zoom", d), .ask)
        XCTAssertEqual(CallPolicy.mode(for: "teams", d), .auto)
    }

    func testAStoredValueFromTheFutureFallsBackToTheDefault() {
        let d = suite()
        d.set(["zoom": "sometimes", "discord": 7] as [String: Any], forKey: CallPolicy.defaultsKey)
        XCTAssertEqual(CallPolicy.mode(for: "zoom", d), .auto)
        XCTAssertEqual(CallPolicy.mode(for: "discord", d), .ask)
    }

    /// The list in Settings is the real registry: every source the detector can produce is in it.
    /// Mutation: CallPolicy.sources, drop "telegram" (or any source) -> RED.
    func testEverySourceTheDetectorCanReturnIsListed() {
        var produced = Set(CallDetector.nativeApps.values)
        for url in ["https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/wc/join/1", "https://acme.zoom.us/j/1",
                    "https://teams.microsoft.com/l/meetup-join/19%3a", "https://teams.live.com/meet/1",
                    "https://oxpulse.chat/GBCD-12345"] {
            if let source = MeetingURL.source(of: url) { produced.insert(source) }
        }
        XCTAssertGreaterThanOrEqual(produced.count, 10)
        XCTAssertEqual(produced.subtracting(CallPolicy.sources), [], "a source the detector returns has no row in Settings")
        XCTAssertEqual(Set(CallPolicy.sources).subtracting(produced), [], "a row in Settings for a source nothing returns")
        XCTAssertEqual(CallPolicy.sources.count, Set(CallPolicy.sources).count)
    }

    func testTheSettingsRowsFollowTheStore() {
        let d = suite()
        CallPolicy.setMode(.never, for: "slack", d)
        let apps = CallPolicy.apps(d)
        XCTAssertEqual(apps.map(\.id), CallPolicy.sources)
        XCTAssertEqual(apps.first { $0.id == "slack" }?.mode, .never)
        XCTAssertEqual(apps.first { $0.id == "meet" }?.name, "Google Meet")
        XCTAssertNotNil(apps.first { $0.id == "meet" }?.noteKey, "a browser call says which browsers are read")
    }

    // MARK: the decision at a detected call

    /// Mutation: MeetingPolicy.onCallStarted(source:mode:…), `.never` returns `.prompt` -> RED.
    func testACallStartsPromptsOrIsLeftAloneByItsAppsMode() {
        func go(_ mode: CallAppMode, autoStart: Bool = true, installing: Bool = false) -> MeetingPolicy.CallStart {
            MeetingPolicy.onCallStarted(source: "zoom", mode: mode, autoStart: autoStart, installing: installing)
        }
        XCTAssertEqual(go(.auto), .start)
        XCTAssertEqual(go(.auto, autoStart: false), .prompt, "the master switch off: nothing records by itself")
        XCTAssertEqual(go(.auto, installing: true), .prompt, "never by itself while an update installs")
        XCTAssertEqual(go(.ask), .prompt)
        XCTAssertEqual(go(.never), .ignore)
        XCTAssertEqual(go(.never, installing: true), .ignore)
        XCTAssertEqual(go(.never, autoStart: false), .ignore)
    }

    func testTheOldDecisionStillMeansTheSame() {
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "zoom", autoStart: true, autoSources: ["zoom"], installing: false), .start)
        XCTAssertEqual(MeetingPolicy.onCallStarted(source: "discord", autoStart: true, autoSources: ["zoom"], installing: false), .prompt)
    }
}
