import XCTest
@testable import DictationCore

/// The decisions behind opening the main window: the delayed return to .accessory, the first launch, the login launch.
final class WindowOpenDecisionsTests: XCTestCase {
    // MARK: the delayed accessory revert (F2)

    func testACloseWithNoOpenAfterItReverts() {
        var revert = AccessoryRevert()
        let ticket = revert.windowClosed()
        XCTAssertTrue(revert.shouldRevert(ticket))
    }

    /// Close, then open inside the revert delay: the pending revert must not win.
    func testAnOpenAfterACloseCancelsThePendingRevert() {
        var revert = AccessoryRevert()
        let ticket = revert.windowClosed()
        revert.windowOpened()
        XCTAssertFalse(revert.shouldRevert(ticket), "a later open must cancel the revert the close scheduled")
    }

    func testOnlyTheLastCloseReverts() {
        var revert = AccessoryRevert()
        let first = revert.windowClosed()
        revert.windowOpened()
        let second = revert.windowClosed()
        XCTAssertFalse(revert.shouldRevert(first))
        XCTAssertTrue(revert.shouldRevert(second))
    }

    // MARK: first launch (F4)

    func testAFreshInstallOpensTheWindow() {
        XCTAssertTrue(FirstLaunch.shouldOpenWindow(markerSet: false, priorRun: false, atLogin: false))
    }

    /// F4: at login the window stays closed, whatever else the state says.
    func testALoginLaunchNeverOpensTheWindow() {
        XCTAssertFalse(FirstLaunch.shouldOpenWindow(markerSet: false, priorRun: false, atLogin: true))
    }

    /// An update installed over a copy that never wrote the marker: the old copy's settings say it ran before.
    func testAnUpdateOverAnOlderCopyDoesNotOpenTheWindow() {
        XCTAssertFalse(FirstLaunch.shouldOpenWindow(markerSet: false, priorRun: true, atLogin: false))
    }

    func testALaterLaunchDoesNotOpenTheWindow() {
        XCTAssertFalse(FirstLaunch.shouldOpenWindow(markerSet: true, priorRun: true, atLogin: false))
        XCTAssertFalse(FirstLaunch.shouldOpenWindow(markerSet: true, priorRun: false, atLogin: false))
    }

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "ox-say-test-first-\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testClaimOpensOnceOnAFreshStore() {
        let d = defaults()
        XCTAssertTrue(FirstLaunch.claim(d, atLogin: false))
        XCTAssertFalse(FirstLaunch.claim(d, atLogin: false), "the second launch is not the first")
    }

    func testClaimAtLoginSpendsTheFirstLaunch() {
        let d = defaults()
        XCTAssertFalse(FirstLaunch.claim(d, atLogin: true))
        XCTAssertFalse(FirstLaunch.claim(d, atLogin: false), "a login launch used the first launch up")
    }

    /// Every real store an earlier version left behind has one of these keys, so its first launch of this version is an update.
    func testEachKeyAnEarlierVersionWroteMarksAPriorRun() {
        XCTAssertGreaterThanOrEqual(FirstLaunch.priorRunKeys.count, 3)
        for key in FirstLaunch.priorRunKeys {
            let d = defaults(key)
            d.set("x", forKey: key)
            XCTAssertFalse(FirstLaunch.claim(d, atLogin: false), "\(key) is evidence of an earlier run")
        }
    }

    // MARK: the login launch event

    func testTheLoginItemOpenEventIsALoginLaunch() {
        XCTAssertTrue(FirstLaunch.isLoginLaunch(eventID: FirstLaunch.openApplicationEvent, propData: FirstLaunch.launchedAsLoginItem))
    }

    func testOtherLaunchesAreNotLoginLaunches() {
        XCTAssertFalse(FirstLaunch.isLoginLaunch(eventID: FirstLaunch.openApplicationEvent, propData: nil))
        XCTAssertFalse(FirstLaunch.isLoginLaunch(eventID: nil, propData: nil))
        XCTAssertFalse(FirstLaunch.isLoginLaunch(eventID: FirstLaunch.openApplicationEvent, propData: FirstLaunch.openApplicationEvent))
    }

    func testTheFourCharacterCodesAreTheAppleEventOnes() {
        XCTAssertEqual(FirstLaunch.openApplicationEvent, 0x6F617070)  // 'oapp'
        XCTAssertEqual(FirstLaunch.launchedAsLoginItem, 0x6C676974)  // 'lgit'
        XCTAssertEqual(FirstLaunch.propDataKeyword, 0x70726F70)  // 'prop'
    }
}
