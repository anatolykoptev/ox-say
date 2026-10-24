import Foundation
import XCTest
@testable import DictationCore

/// The tab read leaves the main thread: at most one read per browser is ever in
/// flight, and the poll only ever consults the last completed result.
final class BrowserTabReadsTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }
    private final class Counter {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Mutation: BrowserTabReads.swift:36, `guard started else` -> `guard started || true else` -> RED.
    func testASlowReadIsNeverQueuedBehindItself() {
        let queue = DispatchQueue(label: "test.tabreads")
        let reads = BrowserTabReads(queue: queue)
        let release = DispatchSemaphore(value: 0)
        let started = Counter()
        let first = reads.request("com.google.Chrome") {
            started.bump()
            release.wait()
            return .url("https://meet.google.com/abc-defg-hij")
        }
        XCTAssertTrue(first)
        // the browser is still being asked (an Automation prompt, a hung script):
        for _ in 0..<5 {
            XCTAssertFalse(reads.request("com.google.Chrome") { started.bump(); return .unreadable },
                           "a read is pending: no second one is queued")
        }
        release.signal()
        queue.sync {}
        XCTAssertEqual(started.value, 1)
        XCTAssertEqual(reads.latest("com.google.Chrome"), .url("https://meet.google.com/abc-defg-hij"))
        // the slot is free again once the read completed
        XCTAssertTrue(reads.request("com.google.Chrome") { .denied })
        queue.sync {}
        XCTAssertEqual(reads.latest("com.google.Chrome"), .denied)
    }

    /// Mutation: BrowserTabReads.swift:34, insert a constant instead of `id` into `inFlight` -> RED.
    func testBrowsersAreIndependent() {
        let queue = DispatchQueue(label: "test.tabreads.two", attributes: .concurrent)
        let reads = BrowserTabReads(queue: queue)
        let release = DispatchSemaphore(value: 0)
        XCTAssertTrue(reads.request("com.google.Chrome") { release.wait(); return .unreadable })
        XCTAssertTrue(reads.request("com.brave.Browser") { .url("https://example.com") },
                      "a hung Chrome must not block Brave's read")
        release.signal()
        queue.sync(flags: .barrier) {}
    }

    /// Nothing completed yet reads as nil; a result is trusted only while fresh.
    /// Mutation: BrowserTabReads.swift:53, drop the `<= maxAge` check -> RED.
    func testOnlyAFreshCompletedResultIsReturned() {
        let clock = Clock()
        let queue = DispatchQueue(label: "test.tabreads.age")
        let reads = BrowserTabReads(maxAge: 10, queue: queue, now: { clock.now })
        let release = DispatchSemaphore(value: 0)
        reads.request("com.google.Chrome") { release.wait(); return .url("https://example.com") }
        XCTAssertNil(reads.latest("com.google.Chrome"), "the read has not completed")
        release.signal()
        queue.sync {}
        XCTAssertEqual(reads.latest("com.google.Chrome"), .url("https://example.com"))
        clock.now = clock.now.addingTimeInterval(9)
        XCTAssertNotNil(reads.latest("com.google.Chrome"))
        clock.now = clock.now.addingTimeInterval(2)
        XCTAssertNil(reads.latest("com.google.Chrome"), "an 11 s old tab is not what the front tab is now")
    }

    func testResetForgetsResults() {
        let queue = DispatchQueue(label: "test.tabreads.reset")
        let reads = BrowserTabReads(queue: queue)
        reads.request("com.google.Chrome") { .denied }
        queue.sync {}
        reads.reset()
        XCTAssertNil(reads.latest("com.google.Chrome"))
    }
}
