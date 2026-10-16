import Foundation

/// A row that can occupy the top of the status menu. The case order is the
/// menu order: Repair above Allow pasting.
public enum TopRow: Int, CaseIterable, Equatable {
    case repair
    case allowPasting
}

/// Which of the conditional top rows to add and drop, decided from what the
/// menu holds right now.
///
/// Both rows are offered only while their condition holds, so either can be
/// due on any menu open or on an open menu when a handshake pass ends. The
/// decision is by MEMBERSHIP, never by "is it the first item": inserting an
/// item that is already in a menu raises `NSInternalInconsistencyException`,
/// which Swift cannot catch, and a first-item test is wrong as soon as two
/// rows share the top.
public enum TopRows {
    public struct Insertion: Equatable {
        public let row: TopRow
        public let index: Int
    }

    public struct Plan: Equatable {
        /// Rows to take out; every one is present now. Applied first.
        public let remove: [TopRow]
        /// Rows to put in, ascending by index; none is present once `remove`
        /// has run. `index` counts from the top of the menu.
        public let insert: [Insertion]
    }

    /// `current` is the managed rows the menu holds now, top to bottom (they
    /// always sit above every other item). After applying the plan the menu
    /// holds exactly the wanted rows in the fixed order Repair, Allow
    /// pasting — also when `current` arrives misordered.
    public static func plan(current: [TopRow], wantRepair: Bool, wantAllowPasting: Bool) -> Plan {
        var desired: [TopRow] = []
        if wantRepair { desired.append(.repair) }
        if wantAllowPasting { desired.append(.allowPasting) }

        var remove: [TopRow] = []
        for row in current where !desired.contains(row) && !remove.contains(row) {
            remove.append(row)
        }
        var kept = current.filter { desired.contains($0) }
        // Present but out of order (or doubled): rebuild rather than patch.
        if kept != desired.filter({ kept.contains($0) }) {
            for row in kept where !remove.contains(row) { remove.append(row) }
            kept = []
        }
        let insert = desired.enumerated()
            .filter { !kept.contains($0.element) }
            .map { Insertion(row: $0.element, index: $0.offset) }
        return Plan(remove: remove, insert: insert)
    }
}
