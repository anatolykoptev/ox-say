import XCTest
@testable import DictationCore

/// The plate can be dragged and remembers where per display (#520).
final class PlatePositionTests: XCTestCase {
    private let a = BadgePlacement.Screen(id: 1, minX: 0, maxX: 1728, maxY: 1084, minY: 0)
    private let b = BadgePlacement.Screen(id: 2, minX: 1728, maxX: 3648, maxY: 1055, minY: 0)

    /// Mutation: BadgePlacement.place, ignore `saved` (use `nil` for left) -> RED.
    func testASavedSpotIsUsedOnAFreshAppearance() {
        let p = BadgePlacement.place(screens: [a, b], placedOn: nil, main: 1, anchoredOffset: nil,
                                     saved: ["1": .init(dx: 100, topInset: 200)], width: 300, height: 36)
        XCTAssertEqual(p?.screenID, 1)
        XCTAssertEqual(p?.x, 100)
        XCTAssertEqual(p?.y, 1084 - 36 - 200)
        XCTAssertEqual(p?.topInset, 200)
    }

    func testEachDisplayRemembersItsOwnSpot() {
        let saved: [String: BadgePlacement.Saved] = ["1": .init(dx: 10, topInset: 8), "2": .init(dx: 500, topInset: 50)]
        let p = BadgePlacement.place(screens: [a, b], placedOn: nil, main: 2, anchoredOffset: nil, saved: saved, width: 300, height: 36)
        XCTAssertEqual(p?.x, 1728 + 500)
        XCTAssertEqual(p?.y, 1055 - 36 - 50)
    }

    func testASavedSpotOutsideTheScreenIsPulledInside() {
        let p = BadgePlacement.place(screens: [a], placedOn: nil, main: 1, anchoredOffset: nil,
                                     saved: ["1": .init(dx: 5000, topInset: 99999)], width: 300, height: 36)
        XCTAssertEqual(p?.x, 1728 - 300)
        XCTAssertEqual(p?.y, 0)
    }

    func testAPlateOnItsScreenKeepsItsDraggedSpotWhenTheWidthChanges() {
        let p = BadgePlacement.place(screens: [a], placedOn: 1, main: 1, anchoredOffset: 40, anchoredInset: 120,
                                     saved: ["1": .init(dx: 900, topInset: 8)], width: 220, height: 36)
        XCTAssertEqual(p?.x, 40)
        XCTAssertEqual(p?.y, 1084 - 36 - 120)
    }

    func testNoSavedSpotKeepsTheOldCentredPlacement() {
        let p = BadgePlacement.place(screens: [a], placedOn: nil, main: 1, anchoredOffset: nil, width: 300, height: 36)
        XCTAssertEqual(p, BadgePlacement.Placement(screenID: 1, x: 864 - 150, y: 1084 - 36 - 8, offset: 714))
    }

    func testStoreRoundTripsPerDisplay() {
        let defaults = UserDefaults(suiteName: "plate-pos-\(UUID().uuidString)")!
        XCTAssertEqual(BadgePositions.load(defaults), [:])
        BadgePositions.save(display: 7, dx: 12.5, topInset: 30, defaults)
        BadgePositions.save(display: 9, dx: 1, topInset: 2, defaults)
        let loaded = BadgePositions.load(defaults)
        XCTAssertEqual(loaded["7"], .init(dx: 12.5, topInset: 30))
        XCTAssertEqual(loaded["9"], .init(dx: 1, topInset: 2))
    }

    func testStoreIgnoresGarbage() {
        let defaults = UserDefaults(suiteName: "plate-pos-\(UUID().uuidString)")!
        defaults.set("not a dictionary", forKey: BadgePositions.key)
        XCTAssertEqual(BadgePositions.load(defaults), [:])
    }
}
