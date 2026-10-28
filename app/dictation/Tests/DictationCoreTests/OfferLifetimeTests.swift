import XCTest
@testable import DictationCore

final class OfferLifetimeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let chrome = [MicUser(bundleID: "com.google.Chrome.helper.Renderer", pid: 5)]

    /// A one-poll microphone dropout (a mute in Meet) must not take the prompt down: the tracker already counted
    /// the call as offered, so a prompt lost here is a missed call.
    /// Mutation: OfferLifetime.shouldHide, `>= Self.callGoneAfter` -> `>= 0` -> RED.
    func testADropoutKeepsThePromptAndASustainedAbsenceHidesIt() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        XCTAssertFalse(life.shouldHide(now: t0, offer: offer, liveSource: "meet", users: chrome))
        XCTAssertFalse(life.shouldHide(now: t0.addingTimeInterval(2), offer: offer, liveSource: nil, users: []), "one poll gone")
        XCTAssertFalse(life.shouldHide(now: t0.addingTimeInterval(4), offer: offer, liveSource: "meet", users: chrome), "it came back")
        // the absence timer restarted: 60 s later is still short of the episode end
        XCTAssertFalse(life.shouldHide(now: t0.addingTimeInterval(6), offer: offer, liveSource: nil, users: []))
        XCTAssertFalse(life.shouldHide(now: t0.addingTimeInterval(66), offer: offer, liveSource: nil, users: []))
        XCTAssertTrue(life.shouldHide(now: t0.addingTimeInterval(6 + OfferLifetime.callGoneAfter), offer: offer, liveSource: nil, users: []),
                      "gone as long as the tracker's episode end: the call is over")
    }

    /// Mutation: OfferLifetime.shouldHide, `if liveSource != nil { ...; return true }` -> `return false` -> RED.
    func testAnotherCallTakesThePromptDown() {
        var life = OfferLifetime()
        XCTAssertTrue(life.shouldHide(now: t0, offer: .prompt(source: "meet"), liveSource: "zoom", users: []))
    }

    /// The consent question is about a browser holding the microphone: when it lets go the question is stale.
    /// Mutation: OfferLifetime.shouldHide, `!CallDetector.holds(...)` -> `false` -> RED.
    func testTheConsentQuestionGoesWhenTheBrowserReleasesTheMic() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.browserConsent(browser: "com.google.Chrome")
        XCTAssertFalse(life.shouldHide(now: t0, offer: offer, liveSource: nil, users: chrome), "a helper process counts as the browser")
        XCTAssertTrue(life.shouldHide(now: t0.addingTimeInterval(2), offer: offer, liveSource: nil, users: []))
    }

    func testNothingUpMeansNothingToHide() {
        var life = OfferLifetime()
        XCTAssertFalse(life.shouldHide(now: t0, offer: nil, liveSource: nil, users: []))
    }

    /// Mutation: OfferLifetime.offersAllowed, `mode != .off` -> `true` -> RED.
    func testOffAllowsNoOffers() {
        XCTAssertFalse(OfferLifetime.offersAllowed(mode: .off))
        XCTAssertTrue(OfferLifetime.offersAllowed(mode: .ask))
        XCTAssertTrue(OfferLifetime.offersAllowed(mode: .auto))
    }
}
