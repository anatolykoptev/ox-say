import XCTest
@testable import DictationCore

private extension OfferLifetime {
    /// The pre-verdict question these tests were written for: does the offer come down.
    mutating func hides(now: Date, offer: Offer?, liveSource: String?, heldOnly: Bool = false, users: [MicUser]) -> Bool {
        verdict(now: now, offer: offer, liveSource: liveSource, heldOnly: heldOnly, users: users) != .keep
    }
}

final class OfferLifetimeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let chrome = [MicUser(bundleID: "com.google.Chrome.helper.Renderer", pid: 5)]

    /// A one-poll microphone dropout (a mute in Meet) must not take the prompt down: the tracker already counted
    /// the call as offered, so a prompt lost here is a missed call.
    /// Mutation: OfferLifetime.verdict, `>= Self.callGoneAfter` -> `>= 0` -> RED.
    func testADropoutKeepsThePromptAndASustainedAbsenceHidesIt() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        XCTAssertFalse(life.hides(now: t0, offer: offer, liveSource: "meet", users: chrome))
        XCTAssertFalse(life.hides(now: t0.addingTimeInterval(2), offer: offer, liveSource: nil, users: []), "one poll gone")
        XCTAssertFalse(life.hides(now: t0.addingTimeInterval(4), offer: offer, liveSource: "meet", users: chrome), "it came back")
        // the absence timer restarted: 60 s later is still short of the episode end
        XCTAssertFalse(life.hides(now: t0.addingTimeInterval(6), offer: offer, liveSource: nil, users: []))
        XCTAssertFalse(life.hides(now: t0.addingTimeInterval(66), offer: offer, liveSource: nil, users: []))
        XCTAssertTrue(life.hides(now: t0.addingTimeInterval(6 + OfferLifetime.callGoneAfter), offer: offer, liveSource: nil, users: []),
                      "gone as long as the tracker's episode end: the call is over")
    }

    /// Mutation: OfferLifetime.verdict, `if liveSource != nil { ...; return true }` -> `return false` -> RED.
    func testAnotherCallTakesThePromptDown() {
        var life = OfferLifetime()
        XCTAssertTrue(life.hides(now: t0, offer: .prompt(source: "meet"), liveSource: "zoom", users: []))
    }

    /// The consent question is about a browser holding the microphone: when it lets go the question is stale.
    /// Mutation: OfferLifetime.verdict, `!CallDetector.holds(...)` -> `false` -> RED.
    func testTheConsentQuestionGoesWhenTheBrowserReleasesTheMic() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.browserConsent(browser: "com.google.Chrome")
        XCTAssertFalse(life.hides(now: t0, offer: offer, liveSource: nil, users: chrome), "a helper process counts as the browser")
        XCTAssertTrue(life.hides(now: t0.addingTimeInterval(2), offer: offer, liveSource: nil, users: []))
    }

    func testNothingUpMeansNothingToHide() {
        var life = OfferLifetime()
        XCTAssertFalse(life.hides(now: t0, offer: nil, liveSource: nil, users: []))
    }

    /// Mutation: OfferLifetime.offersAllowed, `mode != .off` -> `true` -> RED.
    func testOffAllowsNoOffers() {
        XCTAssertFalse(OfferLifetime.offersAllowed(mode: .off))
        XCTAssertTrue(OfferLifetime.offersAllowed(mode: .ask))
        XCTAssertTrue(OfferLifetime.offersAllowed(mode: .auto))
    }

    /// #342.1: heldOnly keeps `tick.call` while the browser holds the mic for another site. A prompt whose call is held
    /// only that way, with the front tab no longer a call, comes down after several polls (not at the first: glancing
    /// at another tab is not leaving the call), and the verdict says the offer was withdrawn, not declined.
    /// Mutation: OfferLifetime.verdict, `heldPolls >= Self.notInFrontPolls` -> `false` -> RED.
    func testAPromptHeldOnlyByTheBrowsersMicComesDownAfterSeveralPolls() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        for poll in 0..<(OfferLifetime.notInFrontPolls - 1) {
            XCTAssertEqual(life.verdict(now: t0.addingTimeInterval(Double(poll) * 2), offer: offer, liveSource: "meet", heldOnly: true, users: chrome),
                           .keep, "poll \(poll)")
        }
        XCTAssertEqual(life.verdict(now: t0.addingTimeInterval(20), offer: offer, liveSource: "meet", heldOnly: true, users: chrome),
                       .hide(.callNotInFront))
        XCTAssertTrue(OfferLifetime.Reason.callNotInFront.withdrawsOffer)
    }

    /// The front tab being a call again (a live read) restarts the count: a user flipping between tabs keeps the prompt.
    /// Mutation: OfferLifetime.verdict, delete `heldPolls = 0` in the live branch -> RED.
    func testALiveReadRestartsTheHeldCount() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        var at = 0.0
        func poll(held: Bool) -> OfferLifetime.Verdict {
            at += 2
            return life.verdict(now: t0.addingTimeInterval(at), offer: offer, liveSource: "meet", heldOnly: held, users: chrome)
        }
        for _ in 0..<3 { for _ in 0..<(OfferLifetime.notInFrontPolls - 1) { XCTAssertEqual(poll(held: true), .keep) }; XCTAssertEqual(poll(held: false), .keep) }
    }

    /// #342.6/7: a prompt that went down because its call was gone for good withdraws the offer (so the returning call is
    /// offered again); another call taking over, or the consent question ending, do not.
    /// Mutation: OfferLifetime.Reason.withdrawsOffer, `self == .callGone || ...` -> `false` -> RED.
    func testOnlyAVanishedCallWithdrawsTheOffer() {
        var life = OfferLifetime()
        let offer = OfferLifetime.Offer.prompt(source: "meet")
        _ = life.verdict(now: t0, offer: offer, liveSource: nil, users: [])
        let gone = life.verdict(now: t0.addingTimeInterval(OfferLifetime.callGoneAfter), offer: offer, liveSource: nil, users: [])
        XCTAssertEqual(gone, .hide(.callGone))
        XCTAssertTrue(OfferLifetime.Reason.callGone.withdrawsOffer)
        XCTAssertFalse(OfferLifetime.Reason.otherCall.withdrawsOffer, "the tracker's episode now belongs to the other call")
        XCTAssertFalse(OfferLifetime.Reason.browserReleased.withdrawsOffer)
        var other = OfferLifetime()
        XCTAssertEqual(other.verdict(now: t0, offer: offer, liveSource: "zoom", users: []), .hide(.otherCall))
        var consent = OfferLifetime()
        XCTAssertEqual(consent.verdict(now: t0, offer: .browserConsent(browser: "com.google.Chrome"), liveSource: nil, users: []), .hide(.browserReleased))
    }

    /// #342.9: the prompt's lifetime is its own number, not the auto-stop's.
    func testThePromptLifetimeHasItsOwnConstant() {
        XCTAssertEqual(OfferLifetime.callGoneAfter, 90)
    }
}
