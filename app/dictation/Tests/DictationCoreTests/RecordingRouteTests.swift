import XCTest
@testable import DictationCore

final class RecordingBufferTests: XCTestCase {
    // Mutation: drop the `epoch == tapEpoch` guard in RecordingBuffer.append
    // -> RED (a tap buffer in flight across stop/start lands in the next
    // recording and its session).
    func testAChunkFromAStoppedRecordingIsDropped() {
        let buf = RecordingBuffer(sampleRate: 16000, maxSeconds: 120)
        var sunk: [[Float]] = []
        buf.onSamples = { sunk.append($0) }
        let a = buf.start()
        XCTAssertEqual(buf.append([1], epoch: a), .stored)
        XCTAssertEqual(buf.stop(), [1])
        XCTAssertEqual(buf.append([9], epoch: a), .stale, "A's tap after A stopped")
        let b = buf.start()
        XCTAssertEqual(buf.append([9], epoch: a), .stale, "A's tap after B started")
        XCTAssertEqual(buf.append([2], epoch: b), .stored)
        XCTAssertEqual(buf.stop(), [2])
        XCTAssertEqual(sunk, [[1], [2]])
    }

    func testAFullRecordingStopsGrowingAndSaysSo() {
        let buf = RecordingBuffer(sampleRate: 10, maxSeconds: 0.2)
        var sunk: [[Float]] = []
        buf.onSamples = { sunk.append($0) }
        let e = buf.start()
        XCTAssertEqual(buf.append([1, 1], epoch: e), .stored)
        XCTAssertEqual(buf.append([2], epoch: e), .full)
        XCTAssertEqual(buf.stop(), [1, 1])
        XCTAssertEqual(sunk, [[1, 1]], "a dropped chunk is not streamed either")
    }
}

final class FeedRouteTests: XCTestCase {
    /// Records every feed; a feed of `blockOn` waits until `release()`.
    final class FeedLog: Transcriber, @unchecked Sendable {
        private let lock = NSLock()
        private var _generation = 1
        private var _fed: [([Float], Int)] = []
        private var _blocked: CheckedContinuation<Void, Never>?
        var blockOn: [Float]?

        var generation: Int {
            get { lock.withLock { _generation } }
            set { lock.withLock { _generation = newValue } }
        }
        var fed: [([Float], Int)] { lock.withLock { _fed } }
        var isBlocked: Bool { lock.withLock { _blocked != nil } }
        func release() { lock.withLock { _blocked }?.resume() }

        func begin() {}
        var feedGeneration: Int { generation }
        func feed(_ samples: [Float], generation g: Int) async {
            if samples == blockOn {
                await withCheckedContinuation { c in lock.withLock { _blocked = c } }
            }
            lock.withLock { _fed.append((samples, g)) }
        }
        func finish(all _: [Float]) async throws -> String { "" }
        func cancel() {}
    }

    // Mutation: read `transcriber.feedGeneration` inside the consumer instead
    // of once in FeedRoute.init -> RED (a chunk of A routed after B's begin()
    // would be retagged as B's and accepted into B's session).
    func testARouteTagsChunksWithTheGenerationItOpenedUnder() async {
        let t = FeedLog()
        let route = FeedRoute(transcriber: t)
        t.generation = 2 // the next dictation began
        route.sink([1])
        await route.drain()
        XCTAssertEqual(t.fed.map(\.0), [[1]])
        XCTAssertEqual(t.fed.map(\.1), [1])
    }

    // Mutation: drop `if Task.isCancelled { break }` in the FeedRoute consumer
    // -> shows whether the stream itself drops what was queued at close.
    func testNothingQueuedIsFedAfterClose() async {
        let t = FeedLog()
        t.blockOn = [1]
        let route = FeedRoute(transcriber: t)
        route.sink([1])
        let deadline = Date().addingTimeInterval(5)
        while !t.isBlocked && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(t.isBlocked, "the first feed must be in flight")
        route.sink([2]) // queued behind the in-flight feed
        route.close()
        route.sink([3]) // after close
        t.release()
        await route.drain()
        XCTAssertEqual(t.fed.map(\.0), [[1]], "only the feed already in flight completes")
    }
}
