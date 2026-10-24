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
        XCTAssertFalse(MeetingSettings.enabled(d), "off until the release that ships it")
        XCTAssertEqual(MeetingSettings.retention(d), .month)
        XCTAssertTrue(MeetingSettings.autoStart(d), "owner decision: on by default")
        XCTAssertFalse(MeetingSettings.explained(d))
        XCTAssertEqual(MeetingSettings.folder(d, home: URL(fileURLWithPath: "/Users/u")).path, "/Users/u/Documents/ox-say Meetings")
        XCTAssertEqual(MeetingSettings.displayName(d, fallback: "Ann"), "Ann")
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

    func testFolderAutoStartNameAndExported() {
        let d = defaults()
        MeetingSettings.setFolder(URL(fileURLWithPath: "/tmp/notes"), d)
        XCTAssertEqual(MeetingSettings.folder(d).path, "/tmp/notes")
        d.set("relative/path", forKey: MeetingSettings.folderKey)
        XCTAssertTrue(MeetingSettings.folder(d, home: URL(fileURLWithPath: "/h")).path.hasPrefix("/h/"), "a relative stored path is ignored")
        MeetingSettings.setAutoStart(false, d)
        XCTAssertFalse(MeetingSettings.autoStart(d))
        MeetingSettings.setDisplayName("  Anatoly ", d)
        XCTAssertEqual(MeetingSettings.displayName(d, fallback: "x"), "Anatoly")
        MeetingSettings.markExported("a", d)
        MeetingSettings.markExported("b", d)
        XCTAssertEqual(MeetingSettings.exported(d), ["a", "b"])
    }
}
