import Foundation
import XCTest
@testable import DictationCore

/// #342.2: under the old scheme a stored per-app `auto` pick was dormant while `meetingsAutoStart` was false;
/// since #341 an explicit pick beats the global Ask, so such an app would now record without a prompt. Once, on the
/// first launch of this version, those picks are dropped.
final class CallPolicyMigrationTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "ox-say-callpolicy-\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private let picks = ["zoom": "auto", "meet": "ask", "teams": "never", "slack": "auto"]

    private func stored(_ d: UserDefaults) -> [String: String] {
        (d.dictionary(forKey: CallPolicy.defaultsKey) as? [String: String]) ?? [:]
    }

    /// The table: legacy flag absent / true / false, marker unset / set.
    /// Mutation: CallPolicy.migrateStaleAutoPicks, `== false` -> `!= false` (or drop the filter) -> RED.
    func testOnlyAStoredFalseDropsTheAutoPicks() {
        let cases: [(legacy: Bool?, marker: Bool, expected: [String: String])] = [
            (nil, false, picks),
            (true, false, picks),
            (false, false, ["meet": "ask", "teams": "never"]),
            (nil, true, picks),
            (true, true, picks),
            (false, true, picks), // already migrated: never again
        ]
        for c in cases {
            let d = defaults()
            d.set(picks, forKey: CallPolicy.defaultsKey)
            if let legacy = c.legacy { d.set(legacy, forKey: CallPolicy.legacyAutoStartKey) }
            if c.marker { d.set(true, forKey: CallPolicy.pickMigrationKey) }
            CallPolicy.migrateStaleAutoPicks(d)
            XCTAssertEqual(stored(d), c.expected, "legacy \(String(describing: c.legacy)) marker \(c.marker)")
            XCTAssertTrue(d.bool(forKey: CallPolicy.pickMigrationKey), "the marker is set after the run")
            if !c.marker {
                XCTAssertNil(d.object(forKey: CallPolicy.legacyAutoStartKey), "the dead key is removed")
            }
        }
    }

    /// Mutation: delete the `guard !d.bool(forKey: pickMigrationKey)` line -> RED (a pick made after the migration
    /// is dropped by a later launch that still finds a stored false).
    func testItRunsOnce() {
        let d = defaults()
        d.set(picks, forKey: CallPolicy.defaultsKey)
        d.set(false, forKey: CallPolicy.legacyAutoStartKey)
        CallPolicy.migrateStaleAutoPicks(d)
        CallPolicy.setMode(.auto, for: "zoom", d) // the user picks auto again, deliberately
        d.set(false, forKey: CallPolicy.legacyAutoStartKey) // however the key came back
        CallPolicy.migrateStaleAutoPicks(d)
        XCTAssertEqual(CallPolicy.pickedMode(for: "zoom", d), .auto)
    }

    func testNothingStoredStillSetsTheMarker() {
        let d = defaults()
        CallPolicy.migrateStaleAutoPicks(d)
        XCTAssertTrue(d.bool(forKey: CallPolicy.pickMigrationKey))
        XCTAssertNil(d.object(forKey: CallPolicy.defaultsKey), "no picks dictionary is invented")
    }

    /// Every pick was `auto`: the emptied dictionary goes, and a row reads as "as set above".
    func testDroppingEveryPickLeavesTheRowsAsSetAbove() {
        let d = defaults()
        d.set(["zoom": "auto"], forKey: CallPolicy.defaultsKey)
        d.set(false, forKey: CallPolicy.legacyAutoStartKey)
        CallPolicy.migrateStaleAutoPicks(d)
        XCTAssertNil(CallPolicy.pickedMode(for: "zoom", d))
    }

    /// A legacy value that is not a Bool is not a stored `false`: the picks stay.
    func testANonBooleanLegacyValueKeepsThePicks() {
        let d = defaults()
        d.set(picks, forKey: CallPolicy.defaultsKey)
        d.set("false", forKey: CallPolicy.legacyAutoStartKey)
        CallPolicy.migrateStaleAutoPicks(d)
        XCTAssertEqual(stored(d), picks)
    }

    /// The call site: the migration runs at launch, before anything reads the picks.
    /// Mutation: AppDelegate.applicationDidFinishLaunching, delete the `CallPolicy.migrateStaleAutoPicks` line -> RED.
    func testTheMigrationRunsAtLaunchBeforeMeetingsAreSetUp() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        let app = try String(contentsOf: path, encoding: .utf8)
        let launch = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching(_ notification: Notification) {"))
        let migrate = try XCTUnwrap(app.range(of: "CallPolicy.migrateStaleAutoPicks(UserDefaults.standard)", range: launch.upperBound..<app.endIndex))
        let setUp = try XCTUnwrap(app.range(of: "setUpMeetings()", range: launch.upperBound..<app.endIndex))
        XCTAssertLessThan(migrate.lowerBound, setUp.lowerBound, "the picks are read before they are migrated")
    }
}
