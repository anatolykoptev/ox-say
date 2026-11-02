import XCTest
@testable import DictationCore

/// The window's route (which section, which meeting) and how it is restored on the next open.
final class MainRouteTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "ox-say-test-route-\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testTheDefaultRouteIsTheMeetingsList() {
        XCTAssertEqual(MainRoute.default, MainRoute(section: .meetings, meetingID: nil))
    }

    func testAHiddenSectionFallsBackToMeetingsAndForgetsTheMeeting() {
        let planned = MainRoute(section: .reel, meetingID: "m1")
        XCTAssertEqual(planned.resolved(visible: [.meetings, .dictation]), .default)
        let live = MainRoute(section: .voices, meetingID: "m1")
        XCTAssertEqual(live.resolved(visible: [.meetings, .voices]), live)
    }

    func testAnEmptyMeetingIDIsNoMeeting() {
        XCTAssertNil(MainRoute(section: .meetings, meetingID: "").resolved(visible: MainWindowSpec.visibleSections).meetingID)
    }

    /// F3: restoration returns the section and the meeting that were saved.
    func testRestorationRoundTripsTheLastSectionAndMeeting() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .voices, meetingID: "2026-11-01-standup"), to: d)
        XCTAssertEqual(WindowRestoration.load(d), MainRoute(section: .voices, meetingID: "2026-11-01-standup"))
    }

    func testNothingSavedOpensTheDefault() {
        XCTAssertEqual(WindowRestoration.load(defaults()), .default)
    }

    func testCorruptDataFallsBackToTheDefaults() {
        let d = defaults()
        d.set(42, forKey: WindowRestoration.sectionKey)
        d.set(["not", "a", "string"], forKey: WindowRestoration.meetingKey)
        XCTAssertEqual(WindowRestoration.load(d), .default)
        d.set("no-such-section", forKey: WindowRestoration.sectionKey)
        d.set("", forKey: WindowRestoration.meetingKey)
        XCTAssertEqual(WindowRestoration.load(d), .default)
    }

    func testASavedSectionThatIsHiddenNowFallsBackToMeetings() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .reel, meetingID: "m9"), to: d)
        XCTAssertEqual(WindowRestoration.load(d, visible: [.meetings, .settings]), .default)
    }

    func testSavingNoMeetingClearsTheOldOne() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .meetings, meetingID: "m1"), to: d)
        WindowRestoration.save(MainRoute(section: .meetings, meetingID: nil), to: d)
        XCTAssertNil(WindowRestoration.load(d).meetingID)
    }

    /// An empty list says nothing about the id — the daemon may still be coming up — so the id stays for a
    /// later list to judge.
    /// Mutation: MainRoute.pruned, remove the empty-list return -> RED.
    func testAnEmptyListJudgesNothing() {
        let route = MainRoute(section: .meetings, meetingID: "m1")
        XCTAssertEqual(route.pruned(knownMeetingIDs: []), route)
    }

    /// A restored meeting that is not in the list any more is dropped once the list is known.
    func testAStaleMeetingIsDroppedAgainstTheKnownList() {
        let route = MainRoute(section: .meetings, meetingID: "gone")
        XCTAssertNil(route.pruned(knownMeetingIDs: ["a", "b"]).meetingID)
        XCTAssertEqual(MainRoute(section: .meetings, meetingID: "a").pruned(knownMeetingIDs: ["a", "b"]).meetingID, "a")
    }
}
