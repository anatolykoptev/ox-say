import XCTest
@testable import DictationCore

/// The plate can be dragged and remembers where per display (#520).
final class PlatePositionTests: XCTestCase {
    private let a = BadgePlacement.Screen(id: 1, minX: 0, maxX: 1728, maxY: 1084, minY: 0, key: "uuid-a")
    private let b = BadgePlacement.Screen(id: 2, minX: 1728, maxX: 3648, maxY: 1055, minY: 0, key: "uuid-b")

    /// Mutation: BadgePlacement.place, ignore `saved` (use `nil` for left) -> RED.
    func testASavedSpotIsUsedOnAFreshAppearance() {
        let p = BadgePlacement.place(screens: [a, b], placedOn: nil, main: 1, anchoredOffset: nil,
                                     saved: ["uuid-a": .init(dx: 100, topInset: 200)], width: 300, height: 36)
        XCTAssertEqual(p?.screenID, 1)
        XCTAssertEqual(p?.x, 100)
        XCTAssertEqual(p?.y, 1084 - 36 - 200)
        XCTAssertEqual(p?.topInset, 200)
    }

    func testEachDisplayRemembersItsOwnSpot() {
        let saved: [String: BadgePlacement.Saved] = ["uuid-a": .init(dx: 10, topInset: 8), "uuid-b": .init(dx: 500, topInset: 50)]
        let p = BadgePlacement.place(screens: [a, b], placedOn: nil, main: 2, anchoredOffset: nil, saved: saved, width: 300, height: 36)
        XCTAssertEqual(p?.x, 1728 + 500)
        XCTAssertEqual(p?.y, 1055 - 36 - 50)
    }

    func testASavedSpotOutsideTheScreenIsPulledInside() {
        let p = BadgePlacement.place(screens: [a], placedOn: nil, main: 1, anchoredOffset: nil,
                                     saved: ["uuid-a": .init(dx: 5000, topInset: 99999)], width: 300, height: 36)
        XCTAssertEqual(p?.x, 1728 - 300)
        XCTAssertEqual(p?.y, 0)
    }

    func testAPlateOnItsScreenKeepsItsDraggedSpotWhenTheWidthChanges() {
        let p = BadgePlacement.place(screens: [a], placedOn: 1, main: 1, anchoredOffset: 40, anchoredInset: 120,
                                     saved: ["uuid-a": .init(dx: 900, topInset: 8)], width: 220, height: 36)
        XCTAssertEqual(p?.x, 40)
        XCTAssertEqual(p?.y, 1084 - 36 - 120)
    }

    func testNoSavedSpotKeepsTheOldCentredPlacement() {
        let p = BadgePlacement.place(screens: [a], placedOn: nil, main: 1, anchoredOffset: nil, width: 300, height: 36)
        XCTAssertEqual(p, BadgePlacement.Placement(screenID: 1, x: 864 - 150, y: 1084 - 36 - 8, offset: 714))
    }

    /// A CGDirectDisplayID is not stable across reconnects: the spot is keyed by the display's UUID, so the same
    /// monitor with a new id gets its spot back. Mutation: BadgePlacement.place, `saved[screen.key]` -> `saved[String(screen.id)]` -> RED.
    func testTheSpotFollowsTheDisplaysKeyNotItsNumericId() {
        let reconnected = BadgePlacement.Screen(id: 77, minX: 0, maxX: 1728, maxY: 1084, minY: 0, key: "uuid-a")
        let p = BadgePlacement.place(screens: [reconnected], placedOn: nil, main: 77, anchoredOffset: nil,
                                     saved: ["uuid-a": .init(dx: 100, topInset: 200)], width: 300, height: 36)
        XCTAssertEqual(p?.x, 100)
        XCTAssertEqual(p?.screenID, 77)
    }

    func testStoreRoundTripsPerDisplay() {
        let defaults = UserDefaults(suiteName: "plate-pos-\(UUID().uuidString)")!
        XCTAssertEqual(BadgePositions.load(defaults), [:])
        BadgePositions.save(key: "u7", dx: 12.5, topInset: 30, defaults)
        BadgePositions.save(key: "u9", dx: 1, topInset: 2, defaults)
        let loaded = BadgePositions.load(defaults)
        XCTAssertEqual(loaded["u7"], .init(dx: 12.5, topInset: 30))
        XCTAssertEqual(loaded["u9"], .init(dx: 1, topInset: 2))
    }

    func testStoreIgnoresGarbage() {
        let defaults = UserDefaults(suiteName: "plate-pos-\(UUID().uuidString)")!
        defaults.set("not a dictionary", forKey: BadgePositions.key)
        XCTAssertEqual(BadgePositions.load(defaults), [:])
    }
}
