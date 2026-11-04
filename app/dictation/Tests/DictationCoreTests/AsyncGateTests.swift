import XCTest
@testable import DictationCore

/// Counts what the waiters of a gate got, safely from any thread.
private final class Got: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ v: Int) { lock.withLock { values.append(v) } }
    var sorted: [Int] { lock.withLock { values.sorted() } }
}

/// The gate the VoiceLibrarySession tests park daemon calls behind. Issue #476: the old one kept one bare
/// continuation with no lock, and a leaked continuation ("wait() leaked its continuation") crashed the suite.
final class AsyncGateTests: XCTestCase {
    /// Waits until `condition` holds, at most `seconds`. False when it never did (a hang is a failed assertion,
    /// not a stuck suite).
    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    /// Two calls parked behind one gate both get the answer. Mutation: resume only `pending.prefix(1)` in
    /// `AsyncGate.open` -> RED ("both waiters are parked" holds, then "both waiters were resumed" fails).
    /// Before the fix the second `wait` overwrote the first one's continuation, which was then never resumed.
    func testEveryWaiterOfAGateIsResumedWhenItOpens() async {
        let gate = AsyncGate<Int>()
        let got = Got()
        let first = Task { got.add(await gate.wait()) }
        let second = Task { got.add(await gate.wait()) }
        let parked = await eventually { gate.parkedCount == 2 }
        XCTAssertTrue(parked, "both waiters are parked (parkedCount \(gate.parkedCount))")
        gate.open(7)
        let resumed = await eventually { got.sorted.count == 2 }
        XCTAssertTrue(resumed, "both waiters were resumed (got \(got.sorted))")
        XCTAssertEqual(got.sorted, [7, 7])
        if resumed { await first.value; await second.value }
    }

    /// A gate opened before anyone waits answers at once, and stays open.
    func testAGateOpenedBeforeAnyWaitAnswersAtOnce() async {
        let gate = AsyncGate<Int>()
        gate.open(3)
        let a = await gate.wait()
        let b = await gate.wait()
        XCTAssertEqual([a, b], [3, 3])
    }
}
