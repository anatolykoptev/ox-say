import Foundation
import XCTest
@testable import DictationCore

final class MeetingSettingsTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "ox-say-meeting-\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaults() {
        let d = defaults()
        XCTAssertTrue(MeetingSettings.enabled(d), "meetings ship on: an unset flag means on")
        XCTAssertEqual(MeetingSettings.retention(d), .month)
        XCTAssertEqual(MeetingSettings.callMode(d), .ask, "nothing records by itself until the user says so")
        XCTAssertFalse(MeetingSettings.explained(d))
        XCTAssertEqual(MeetingSettings.folder(d, home: URL(fileURLWithPath: "/Users/u")).path, "/Users/u/Documents/ox-say Meetings")
        XCTAssertEqual(MeetingSettings.displayName(d, fallback: "Ann"), "Ann")
    }

    /// The flag is on by default but an explicit off still wins; the global mode round trips and an unknown
    /// stored value asks.
    /// Mutation (F1): MeetingSettings.enabled, back to `d.bool(forKey: enabledKey)` -> RED (testDefaults).
    /// Mutation: MeetingSettings.callMode, `?? .ask` -> `?? .auto` -> RED.
    func testTheFlagAndTheGlobalModeRoundTrip() {
        let d = defaults()
        d.set(false, forKey: MeetingSettings.enabledKey)
        XCTAssertFalse(MeetingSettings.enabled(d))
        for mode in CallGlobalMode.allCases {
            MeetingSettings.setCallMode(mode, d)
            XCTAssertEqual(MeetingSettings.callMode(d), mode)
        }
        d.set("sometimes", forKey: MeetingSettings.callModeKey)
        XCTAssertEqual(MeetingSettings.callMode(d), .ask)
        d.set(3, forKey: MeetingSettings.callModeKey)
        XCTAssertEqual(MeetingSettings.callMode(d), .ask, "a non-string stored value asks too")
        // The retired boolean is ignored: whatever it says, the mode is the mode.
        d.set(false, forKey: "meetingsAutoStart")
        XCTAssertEqual(MeetingSettings.callMode(d), .ask)
    }

    /// The four retention picks round trip, "never delete" included: 0 must not read as "unset".
    /// Mutation: MeetingSettings.retention, delete the `guard d.object(forKey: retentionKey) != nil`
    /// line (an unset key then reads 0 = keep forever) -> RED (testDefaults).
    func testRetentionRoundTripsAndAnUnknownValueIsThirtyDays() {
        let d = defaults()
        for r in MeetingRetention.allCases {
            MeetingSettings.setRetention(r, d)
            XCTAssertEqual(MeetingSettings.retention(d), r)
        }
        d.set(45, forKey: MeetingSettings.retentionKey)
        XCTAssertEqual(MeetingSettings.retention(d), .month)
        XCTAssertEqual(MeetingRetention.forever.days, 0)
    }

    func testFolderModeNameAndExported() {
        let d = defaults()
        MeetingSettings.setFolder(URL(fileURLWithPath: "/tmp/notes"), d)
        XCTAssertEqual(MeetingSettings.folder(d).path, "/tmp/notes")
        d.set("relative/path", forKey: MeetingSettings.folderKey)
        XCTAssertTrue(MeetingSettings.folder(d, home: URL(fileURLWithPath: "/h")).path.hasPrefix("/h/"), "a relative stored path is ignored")
        MeetingSettings.setCallMode(.off, d)
        XCTAssertEqual(MeetingSettings.callMode(d), .off)
        MeetingSettings.setDisplayName("  Anatoly ", d)
        XCTAssertEqual(MeetingSettings.displayName(d, fallback: "x"), "Anatoly")
        MeetingSettings.markExported("a", d)
        MeetingSettings.markExported("b", d)
        XCTAssertEqual(MeetingSettings.exported(d), ["a", "b"])
    }
}
