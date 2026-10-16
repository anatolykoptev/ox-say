import XCTest
@testable import DictationCore

final class TopRowsTests: XCTestCase {
    /// A stand-in for NSMenu's top block that fails the way AppKit does:
    /// inserting a row it already holds, or removing one it lacks, is a
    /// crash in production, so here it is a recorded violation.
    private struct FakeMenu {
        var rows: [TopRow]
        var violations: [String] = []

        mutating func apply(_ plan: TopRows.Plan) {
            for row in plan.remove {
                if let at = rows.firstIndex(of: row) { rows.remove(at: at) }
                else { violations.append("removed absent \(row)") }
            }
            for ins in plan.insert {
                if rows.contains(ins.row) { violations.append("inserted present \(ins.row)"); continue }
                rows.insert(ins.row, at: min(ins.index, rows.count))
            }
        }

        mutating func open(wantRepair: Bool, wantAllowPasting: Bool) {
            apply(TopRows.plan(current: rows, wantRepair: wantRepair, wantAllowPasting: wantAllowPasting))
        }
    }

    private let arrangements: [[TopRow]] = [[], [.repair], [.allowPasting], [.repair, .allowPasting], [.allowPasting, .repair]]

    func testEveryPresentAndWantedCombinationEndsInTheFixedOrder() {
        for current in arrangements {
            for wantRepair in [false, true] {
                for wantAllow in [false, true] {
                    var menu = FakeMenu(rows: current)
                    menu.open(wantRepair: wantRepair, wantAllowPasting: wantAllow)
                    let expected = (wantRepair ? [TopRow.repair] : []) + (wantAllow ? [.allowPasting] : [])
                    let label = "current \(current) wantRepair \(wantRepair) wantAllow \(wantAllow)"
                    XCTAssertEqual(menu.rows, expected, label)
                    XCTAssertEqual(menu.violations, [], label)
                }
            }
        }
    }

    func testARowAlreadyPresentIsNeverInsertedAgain() {
        for current in arrangements {
            let plan = TopRows.plan(current: current, wantRepair: true, wantAllowPasting: true)
            let afterRemoval = current.filter { !plan.remove.contains($0) }
            for ins in plan.insert {
                XCTAssertFalse(afterRemoval.contains(ins.row), "re-inserts \(ins.row) into \(current)")
            }
        }
    }

    func testOnlyPresentRowsAreRemoved() {
        for current in arrangements {
            for wantRepair in [false, true] {
                for wantAllow in [false, true] {
                    let plan = TopRows.plan(current: current, wantRepair: wantRepair, wantAllowPasting: wantAllow)
                    for row in plan.remove {
                        XCTAssertTrue(current.contains(row), "removes absent \(row) from \(current)")
                    }
                }
            }
        }
    }

    func testBothRowsDueAcrossTwoOpensLeavesTheMenuAlone() {
        var menu = FakeMenu(rows: [])
        menu.open(wantRepair: true, wantAllowPasting: true)
        XCTAssertEqual(menu.rows, [.repair, .allowPasting])
        let second = TopRows.plan(current: menu.rows, wantRepair: true, wantAllowPasting: true)
        XCTAssertEqual(second, TopRows.Plan(remove: [], insert: []), "the second open must change nothing")
        menu.open(wantRepair: true, wantAllowPasting: true)
        XCTAssertEqual(menu.rows, [.repair, .allowPasting])
        XCTAssertEqual(menu.violations, [])
    }

    func testRowsComeAndGoAcrossOpensInTheFixedOrder() {
        var menu = FakeMenu(rows: [])
        let opens: [(repair: Bool, allow: Bool, rows: [TopRow])] = [
            (false, true, [.allowPasting]),
            (true, true, [.repair, .allowPasting]),   // Repair joins above Allow
            (true, false, [.repair]),
            (true, true, [.repair, .allowPasting]),   // Allow joins below Repair
            (false, true, [.allowPasting]),
            (false, false, []),
        ]
        for (i, open) in opens.enumerated() {
            menu.open(wantRepair: open.repair, wantAllowPasting: open.allow)
            XCTAssertEqual(menu.rows, open.rows, "open \(i)")
        }
        XCTAssertEqual(menu.violations, [])
    }

    func testAMisorderedMenuIsRebuiltInTheFixedOrder() {
        var menu = FakeMenu(rows: [.allowPasting, .repair])
        menu.open(wantRepair: true, wantAllowPasting: true)
        XCTAssertEqual(menu.rows, [.repair, .allowPasting])
        XCTAssertEqual(menu.violations, [])
    }
}
