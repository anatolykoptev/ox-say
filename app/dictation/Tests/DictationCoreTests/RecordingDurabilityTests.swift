import Foundation
import XCTest
@testable import DictationCore

/// #531: a recording survives what kills the app or the Mac. The audio is on its way to the disk the moment it is
/// appended, the files are flushed on a fixed short cadence, and an activity is held for the length of the recording.
final class RecordingDurabilityTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-dur-\(UUID().uuidString).pcm")
    }

    /// The bound on what a power loss costs is a number: pin it where the recorder reads it.
    /// Mutation: RecordingDurability.flushInterval, 2 -> 30 -> RED.
    func testTheFlushIntervalIsAtMostTwoSeconds() {
        XCTAssertLessThanOrEqual(RecordingDurability.flushInterval, 2)
        XCTAssertGreaterThan(RecordingDurability.flushInterval, 0)
    }

    /// `kill -9` takes the process, not the kernel's copy of what it wrote: an appended chunk is readable by another
    /// handle BEFORE the channel is finished or flushed. A writer that buffered in the process would fail this.
    /// Mutation: PcmChannelWriter.write, collect the data in an array and write it in `finish` -> RED.
    func testAppendedAudioIsInTheFileBeforeFinish() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 1_000)
        w.append([Float](repeating: 0.25, count: 1600), atNanos: 1_000)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, 3200, "100 ms of audio is in the file with the writer still open")
        w.finish(atNanos: 1_000 + 100_000_000)
    }

    /// `flush` runs the sync on a live descriptor of the channel's own file, and counts it.
    /// Mutation: PcmChannelWriter.flush, delete the `sync(fd)` call -> RED (never synced).
    func testFlushSyncsALiveDescriptorOfTheChannelFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var seen: [Bool] = []
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        let w = PcmChannelWriter(handle: handle, t0: 1_000, sync: { fd in
            // A live descriptor: F_GETFD answers, and it is a different number from the handle's own (a dup).
            seen.append(fcntl(fd, F_GETFD) != -1 && fd != handle.fileDescriptor)
            return true
        })
        w.append([0.1, 0.1], atNanos: 1_000)
        w.flush()
        w.flush()
        XCTAssertEqual(seen, [true, true])
        XCTAssertEqual(w.flushCount, 2)
        w.finish(atNanos: 1_000) // its own final sync is the next test's subject
    }

    /// A sync the disk refuses is visible: `flush` says so and the writer counts it, so the recorder can log it.
    /// Mutation: PcmChannelWriter.flush, `if !ok { lock.withLock { syncFailed += 1 } }` deleted -> RED.
    func testARefusedSyncIsCountedAndReported() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        var answers = [false, true, true] // the third is the final sync of `finish`
        let w = PcmChannelWriter(handle: handle, t0: 1_000, sync: { _ in answers.removeFirst() })
        XCTAssertFalse(w.flush())
        XCTAssertEqual(w.syncFailures, 1)
        XCTAssertTrue(w.flush())
        XCTAssertEqual(w.syncFailures, 1, "a later good sync does not erase the count")
        w.finish(atNanos: 1_000)
    }

    /// A finished channel has a closed file: a late tick of the timer must neither crash nor sync.
    /// Mutation: PcmChannelWriter.finish, delete `closed = true` -> RED (a sync on a closed handle's descriptor).
    func testFlushAfterFinishDoesNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        let w = PcmChannelWriter(handle: handle, t0: 1_000, sync: { _ in calls += 1; return true })
        w.finish(atNanos: 1_000)
        let atFinish = calls
        w.flush()
        XCTAssertEqual(calls, atFinish, "a tick after the close syncs nothing")
        XCTAssertEqual(w.flushCount, 0)
    }

    /// A clean stop ends with one more sync, on the descriptor of the file as it ends (after the pad to the end time,
    /// before the close): the last 2 s since the timer's final tick are on the disk, not left to the kernel.
    /// Mutation: PcmChannelWriter.finish, delete the `if !sync(handle.fileDescriptor) { syncFailed += 1 }` line -> RED;
    /// move it below `try? handle.close()` -> RED (the descriptor is already closed).
    func testFinishSyncsTheFileOnceMoreBeforeItCloses() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        var live: [Bool] = []
        var sizeAtSync: [UInt64] = []
        let w = PcmChannelWriter(handle: handle, t0: 0, sync: { fd in
            live.append(fcntl(fd, F_GETFD) != -1)
            var info = stat()
            sizeAtSync.append(fstat(fd, &info) == 0 ? UInt64(info.st_size) : 0)
            return true
        })
        w.append([0.1, 0.1], atNanos: 0)
        w.finish(atNanos: 1_000_000_000) // padded to one second: 32000 bytes
        XCTAssertEqual(live, [true], "exactly one sync, on a descriptor that is still open")
        XCTAssertEqual(sizeAtSync, [32000], "after the pad: the file that is synced is the finished one")
        XCTAssertEqual(w.flushCount, 0, "it is not a timer flush")
    }

    /// A refusal of the final sync is counted like any other.
    /// Mutation: PcmChannelWriter.finish, `{ syncFailed += 1 }` -> `{ }` -> RED.
    func testARefusedFinalSyncIsCounted() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        let w = PcmChannelWriter(handle: handle, t0: 1_000, sync: { _ in false })
        w.finish(atNanos: 1_000)
        XCTAssertEqual(w.syncFailures, 1)
    }

    /// The real sync really runs on a real file.
    func testTheRealFlushDoesNotFailOnARealFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 1_000)
        w.append([Float](repeating: 0.1, count: 160), atNanos: 1_000)
        w.flush()
        XCTAssertEqual(w.flushCount, 1)
        w.finish(atNanos: 1_000 + 10_000_000)
    }

    /// The timer calls the action repeatedly at the interval, a second start adds no second timer, and stop means stop.
    /// It waits for the ticks on an expectation instead of a fixed sleep, so a loaded runner can be slow without failing it (#636).
    /// Mutation: PeriodicFlush.start, `repeating: interval` -> `repeating: .infinity` -> RED (one tick only, the wait times out).
    /// Mutation: PeriodicFlush.start, a second start() that keeps the first timer alive beside the new one -> RED (4th tick at ~104 ms).
    /// Merely deleting the `guard timer == nil` line is NOT observable: the displaced timer is released and libdispatch cancels it.
    func testThePeriodicFlushTicksRepeatedlyAndStops() {
        let interval = 0.05
        let ticks = NSLock()
        var n = 0
        var fourthAt: UInt64 = 0
        let four = expectation(description: "four ticks")
        four.expectedFulfillmentCount = 4
        four.assertForOverFulfill = false
        let flush = PeriodicFlush(interval: interval, action: {
            let now = DispatchTime.now().uptimeNanoseconds
            ticks.withLock {
                n += 1
                if n == 4 { fourthAt = now }
            }
            four.fulfill()
        })
        XCTAssertFalse(flush.isRunning)
        let t0 = DispatchTime.now().uptimeNanoseconds // before start(), so the elapsed time can only be over-measured
        flush.start()
        flush.start() // a second start must not add a second timer
        XCTAssertTrue(flush.isRunning)
        wait(for: [four], timeout: 5)
        flush.stop()
        let atStop = ticks.withLock { n }
        XCTAssertGreaterThanOrEqual(atStop, 4, "ticked repeatedly, not once")
        // A single timer has its k-th tick no earlier than start + k * interval (a timer fires late under load, never early),
        // so the 4th tick is >= 200 ms after start(). Two timers started together reach the 4th tick after 2 intervals (~100 ms).
        // 180 ms separates them; only a too-EARLY 4th tick fails here, slowness never does.
        let elapsedMs = Double(ticks.withLock { fourthAt } &- t0) / 1_000_000
        XCTAssertGreaterThanOrEqual(elapsedMs, 180, "a second timer would reach 4 ticks in about half the time")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(ticks.withLock { n }, atStop, "stopped means stopped")
        XCTAssertFalse(flush.isRunning)
    }

    /// One begin per hold, however many times it is asked, and the same token is the one ended.
    /// Mutation: ActivityHold.hold, delete the `token == nil` guard -> RED (a leaked second activity).
    /// Mutation: ActivityHold.release, delete the `end(t)` call -> RED (the Mac can never sleep again).
    func testTheActivityIsBegunOnceAndEndedOnce() {
        var begun: [String] = []
        var ended = 0
        let tokens = NSMutableArray()
        let hold = ActivityHold(begin: { reason in
            begun.append(reason)
            let t = NSObject()
            tokens.add(t)
            return t
        }, end: { t in
            XCTAssertTrue(tokens.contains(t), "the token that was begun is the one ended")
            ended += 1
        })
        XCTAssertFalse(hold.isHeld)
        hold.hold(reason: "recording")
        hold.hold(reason: "recording")
        XCTAssertTrue(hold.isHeld)
        XCTAssertEqual(begun, ["recording"])
        hold.release()
        hold.release()
        XCTAssertFalse(hold.isHeld)
        XCTAssertEqual(ended, 1)
        hold.hold(reason: "again")
        XCTAssertEqual(begun.count, 2, "a second recording holds its own")
        hold.release()
    }

    /// The recorder carries the pieces out (the shim compiles DictationCore only, so this reads the source as text):
    /// the flush timer and the activity start with the recording and end with it, and the timer syncs both channels
    /// outside the writers' lock.
    /// Mutations: MeetingRecorder.start, delete `flusher.start()` -> RED; delete `activity.hold(` -> RED;
    /// MeetingRecorder.stop, delete `flusher.stop()` -> RED; delete `activity.release()` -> RED;
    /// MeetingRecorder.flushChannels, delete the `t?.flush()` line -> RED.
    func testTheRecorderStartsAndEndsTheFlushAndTheActivity() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/MeetingRecorder.swift")
        let code = MeetingWiringTests.stripComments(try String(contentsOf: file, encoding: .utf8))
        func body(of signature: String) throws -> String {
            let start = try XCTUnwrap(code.range(of: signature), "\(signature) not found")
            let rest = code[start.upperBound...]
            // The body ends at the nearest following member declaration.
            let ends = ["\n    func ", "\n    private func ", "\n    static func ", "\n    @discardableResult"]
                .compactMap { rest.range(of: $0)?.lowerBound }
            return String(rest[..<(ends.min() ?? rest.endIndex)])
        }
        let start = try body(of: "func start(into dir: URL")
        XCTAssertTrue(start.contains("flusher.start()"))
        XCTAssertTrue(start.contains("activity.hold("))
        let stop = try body(of: "func stop() -> Summary {")
        XCTAssertTrue(stop.contains("flusher.stop()"))
        XCTAssertTrue(stop.contains("activity.release()"))
        let flush = try body(of: "private func flushChannels() {")
        XCTAssertTrue(flush.contains("m?.flush()") && flush.contains("t?.flush()"))
        XCTAssertFalse(flush.contains("writersLock.withLock { m?"), "the sync must not run under the writers' lock")
    }
}
