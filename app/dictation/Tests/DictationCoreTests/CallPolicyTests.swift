import Foundation
import XCTest
@testable import DictationCore

/// Per-app record / ask / don't record, layered on the global call mode.
final class CallPolicyTests: XCTestCase {
    private func suite() -> UserDefaults {
        let d = UserDefaults(suiteName: "mw2-callpolicy-\(UUID().uuidString)")!
        return d
    }

    /// An app nobody picked follows the global mode — under Ask everything asks, under Auto the work-call
    /// sources record by themselves and the messengers still ask.
    /// Mutation (F2): CallPolicy.effectiveMode, `case .ask: return .ask` -> `return defaultMode(source)` -> RED.
    /// Mutation: CallPolicy.defaultMode, `.ask` -> `.auto` for the else branch (or drop the autoStartSources test) -> RED.
    func testTheUnpickedFollowTheGlobalMode() {
        for source in CallPolicy.sources {
            XCTAssertEqual(CallPolicy.effectiveMode(for: source, global: .ask, picked: nil), .ask, source)
            XCTAssertEqual(CallPolicy.effectiveMode(for: source, global: .off, picked: nil), .never, source)
        }
        for source in ["zoom", "teams", "webex", "meet", "oxpulse"] {
            XCTAssertEqual(CallPolicy.effectiveMode(for: source, global: .auto, picked: nil), .auto, source)
        }
        for source in ["discord", "whatsapp", "telegram", "slack", "facetime"] {
            XCTAssertEqual(CallPolicy.effectiveMode(for: source, global: .auto, picked: nil), .ask, source)
        }
        XCTAssertEqual(Set(CallDetector.autoStartSources.filter { CallPolicy.sources.contains($0) }),
                       Set(CallPolicy.sources.filter { CallPolicy.defaultMode($0) == .auto }),
                       "the auto defaults are derived from the detector, not retyped")
    }

    /// A pick wins over global ask/auto; global Off wins over every pick.
    /// Mutation: CallPolicy.effectiveMode, `if let picked { return global == .off ? .never : picked }` -> `if let picked { return picked }` -> RED.
    func testAPickBeatsTheGlobalModeAndOffBeatsEveryPick() {
        XCTAssertEqual(CallPolicy.effectiveMode(for: "slack", global: .ask, picked: .auto), .auto)
        XCTAssertEqual(CallPolicy.effectiveMode(for: "zoom", global: .auto, picked: .ask), .ask)
        XCTAssertEqual(CallPolicy.effectiveMode(for: "zoom", global: .auto, picked: .never), .never)
        XCTAssertEqual(CallPolicy.effectiveMode(for: "telegram", global: .auto, picked: .auto), .auto, "an explicit pick beats the messenger ask")
        for picked in [CallAppMode.auto, .ask, .never] {
            for source in CallPolicy.sources {
                XCTAssertEqual(CallPolicy.effectiveMode(for: source, global: .off, picked: picked), .never, "\(source) \(picked)")
            }
        }
    }

    func testAnAppNobodyKnowsAsksFirst() {
        XCTAssertEqual(CallPolicy.effectiveMode(for: "newcallapp", global: .ask, picked: nil), .ask)
        XCTAssertEqual(CallPolicy.effectiveMode(for: "newcallapp", global: .auto, picked: nil), .ask, "an unknown source is not in autoStartSources")
    }

    func testAPickIsStoredPerAppAndOnlyForThatApp() {
        let d = suite()
        CallPolicy.setMode(.never, for: "discord", d)
        CallPolicy.setMode(.ask, for: "zoom", d)
        XCTAssertEqual(CallPolicy.pickedMode(for: "discord", d), .never)
        XCTAssertEqual(CallPolicy.pickedMode(for: "zoom", d), .ask)
        XCTAssertNil(CallPolicy.pickedMode(for: "teams", d), "never picked is nil: the row follows the global mode")
    }

    /// "As set above" removes the stored pick: the app follows the global mode again.
    /// Mutation: CallPolicy.setMode, `all[source] = mode?.rawValue` -> `all[source] = mode!.rawValue` -> RED (crash, not a cleared pick).
    func testAsSetAboveRemovesThePick() {
        let d = suite()
        CallPolicy.setMode(.never, for: "slack", d)
        CallPolicy.setMode(nil, for: "slack", d)
        XCTAssertNil(CallPolicy.pickedMode(for: "slack", d))
        XCTAssertEqual(CallPolicy.effectiveMode(for: "slack", global: .auto, picked: CallPolicy.pickedMode(for: "slack", d)), .ask)
    }

    func testAStoredValueFromTheFutureFallsBackToNoPick() {
        let d = suite()
        d.set(["zoom": "sometimes", "discord": 7] as [String: Any], forKey: CallPolicy.defaultsKey)
        XCTAssertNil(CallPolicy.pickedMode(for: "zoom", d))
        XCTAssertNil(CallPolicy.pickedMode(for: "discord", d))
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

    func testThePictureRowsAreTheRealRegistryUnpicked() {
        let apps = CallPolicy.defaultApps()
        XCTAssertEqual(apps.map(\.id), CallPolicy.sources)
        XCTAssertTrue(apps.contains { $0.id == "oxpulse" })
        XCTAssertEqual(apps.filter { $0.mode != nil }.count, 0, "a picture row is never pre-picked")
    }

    func testTheSettingsRowsFollowTheStore() {
        let d = suite()
        CallPolicy.setMode(.never, for: "slack", d)
        let apps = CallPolicy.apps(d)
        XCTAssertEqual(apps.map(\.id), CallPolicy.sources)
        XCTAssertEqual(apps.first { $0.id == "slack" }?.mode, .never)
        XCTAssertNil(apps.first { $0.id == "zoom" }?.mode, "unpicked rows carry no pick")
        XCTAssertEqual(apps.first { $0.id == "meet" }?.name, "Google Meet")
        XCTAssertNotNil(apps.first { $0.id == "meet" }?.noteKey, "a browser call says which browsers are read")
    }
}
