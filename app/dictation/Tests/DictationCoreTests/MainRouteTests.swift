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

    func testTheDefaultRouteIsTheFirstRunSection() {
        XCTAssertEqual(MainRoute.default, MainRoute(section: MainWindowSpec.firstRunSection, meetingID: nil))
    }

    func testAHiddenSectionFallsBackToTheDefaultAndForgetsTheMeeting() {
        let hidden = MainRoute(section: .models, meetingID: "m1")
        XCTAssertEqual(hidden.resolved(visible: [.meetings, .dictation]), .default)
        let live = MainRoute(section: .voices, meetingID: "m1")
        XCTAssertEqual(live.resolved(visible: [.meetings, .voices]), live)
    }

    func testAnEmptyMeetingIDIsNoMeeting() {
        XCTAssertNil(MainRoute(section: .meetings, meetingID: "").resolved(visible: MainWindowSpec.sections(advanced: true)).meetingID)
    }

    /// F3: restoration returns the section and the meeting that were saved.
    func testRestorationRoundTripsTheLastSectionAndMeeting() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .voices, meetingID: "2026-11-01-standup"), to: d)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false), MainRoute(section: .voices, meetingID: "2026-11-01-standup"))
    }

    func testNothingSavedOpensTheDefault() {
        XCTAssertEqual(WindowRestoration.load(defaults(), advanced: false), .default)
    }

    func testCorruptDataFallsBackToTheDefaults() {
        let d = defaults()
        d.set(42, forKey: WindowRestoration.sectionKey)
        d.set(["not", "a", "string"], forKey: WindowRestoration.meetingKey)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false), .default)
        d.set("no-such-section", forKey: WindowRestoration.sectionKey)
        d.set("", forKey: WindowRestoration.meetingKey)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false), .default)
    }

    func testASavedSectionThatIsHiddenNowFallsBackToTheDefault() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .models, meetingID: "m9"), to: d)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false), .default)
    }

    func testSavingNoMeetingClearsTheOldOne() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .meetings, meetingID: "m1"), to: d)
        WindowRestoration.save(MainRoute(section: .meetings, meetingID: nil), to: d)
        XCTAssertNil(WindowRestoration.load(d, advanced: false).meetingID)
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

    /// Window Task 18 F3: the voiceover that is open is saved and restored with the section.
    func testRouteRoundTripsTheVoiceoverID() {
        let d = defaults()
        WindowRestoration.save(MainRoute(section: .speak, speakID: "20261110-101500-abc123"), to: d)
        XCTAssertEqual(WindowRestoration.load(d, advanced: false).speakID, "20261110-101500-abc123")
        XCTAssertEqual(d.string(forKey: "mainWindow.speak"), "20261110-101500-abc123")
        WindowRestoration.save(MainRoute(section: .speak, speakID: nil), to: d)
        XCTAssertNil(WindowRestoration.load(d, advanced: false).speakID, "no voiceover clears the old one")
    }

    func testAStaleVoiceoverIDIsPrunedLikeAMeeting() {
        let route = MainRoute(section: .speak, speakID: "gone")
        XCTAssertNil(route.pruned(knownSpeakIDs: ["a", "b"]).speakID)
        XCTAssertEqual(route.pruned(knownSpeakIDs: ["gone", "b"]).speakID, "gone")
        XCTAssertEqual(route.pruned(knownSpeakIDs: []).speakID, "gone", "an empty list says nothing yet")
        XCTAssertEqual(MainRoute(section: .speak, meetingID: "m", speakID: "gone").pruned(knownSpeakIDs: ["a"]).meetingID, "m")
        XCTAssertNil(MainRoute(section: .speak, speakID: "").resolved().speakID)
    }
}
