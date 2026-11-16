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
        })
        w.append([0.1, 0.1], atNanos: 1_000)
        w.flush()
        w.flush()
        XCTAssertEqual(seen, [true, true])
        XCTAssertEqual(w.flushCount, 2)
        w.finish(atNanos: 1_000)
    }

    /// A finished channel has a closed file: a late tick of the timer must neither crash nor sync.
    /// Mutation: PcmChannelWriter.finish, delete `closed = true` -> RED (a sync on a closed handle's descriptor).
    func testFlushAfterFinishDoesNothing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        let handle = try { _ = FileManager.default.createFile(atPath: url.path, contents: nil); return try FileHandle(forWritingTo: url) }()
        let w = PcmChannelWriter(handle: handle, t0: 1_000, sync: { _ in calls += 1 })
        w.finish(atNanos: 1_000)
        w.flush()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(w.flushCount, 0)
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

    /// The timer calls the action repeatedly at the interval, and stops when told.
    /// Mutation: PeriodicFlush.start, `repeating: interval` -> `repeating: .infinity` -> RED (one tick only).
    func testThePeriodicFlushTicksRepeatedlyAndStops() {
        let ticks = NSLock()
        var n = 0
        let flush = PeriodicFlush(interval: 0.05, action: { ticks.withLock { n += 1 } })
        XCTAssertFalse(flush.isRunning)
        flush.start()
        flush.start() // a second start must not add a second timer
        XCTAssertTrue(flush.isRunning)
        Thread.sleep(forTimeInterval: 0.42)
        flush.stop()
        let atStop = ticks.withLock { n }
        XCTAssertGreaterThanOrEqual(atStop, 4, "ticked about every 50 ms for 420 ms")
        XCTAssertLessThanOrEqual(atStop, 10, "a second timer would double it")
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

    /// After a sleep: the microphone is restarted only when it is not running, the tap is rebuilt when it has not
    /// delivered for more than a second or has never delivered.
    /// Mutation: RecordingDurability.onWake, `!micRunning` -> `micRunning` -> RED; `$0 > tapAliveWithin` -> `$0 < ...` -> RED.
    func testWakeRestartsOnlyWhatStopped() {
        XCTAssertEqual(RecordingDurability.onWake(micRunning: true, tapSilence: 0.01), RecordingDurability.WakeActions(restartMicrophone: false, rebuildTap: false))
        XCTAssertEqual(RecordingDurability.onWake(micRunning: false, tapSilence: 0.01), RecordingDurability.WakeActions(restartMicrophone: true, rebuildTap: false))
        XCTAssertEqual(RecordingDurability.onWake(micRunning: true, tapSilence: 3600), RecordingDurability.WakeActions(restartMicrophone: false, rebuildTap: true))
        XCTAssertEqual(RecordingDurability.onWake(micRunning: true, tapSilence: nil), RecordingDurability.WakeActions(restartMicrophone: false, rebuildTap: true))
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
        let start = try body(of: "func start(into dir: URL) throws {")
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
