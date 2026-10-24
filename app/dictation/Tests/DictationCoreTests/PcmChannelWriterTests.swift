import Foundation
import XCTest
@testable import DictationCore

final class PcmChannelWriterTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ox-say-pcm-\(UUID().uuidString).pcm")
    }

    private func samples(_ url: URL) throws -> [Int16] {
        let d = try Data(contentsOf: url)
        return stride(from: 0, to: d.count - 1, by: 2).map { Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8) }
    }

    func testChunksAreAppendedAsInt16AndClamped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 1_000)
        w.append([0, 0.5, -0.5, 2, -2], atNanos: 1_000)
        w.finish(atNanos: 1_000)
        let s = try samples(url)
        XCTAssertEqual(s, [0, 16383, -16383, 32767, -32767])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "audio is private")
    }

    /// A channel that starts late is padded, so its samples sit at their time in the meeting.
    /// Mutation: PcmChannelWriter.append, change `expected - written > Self.gapTolerance`
    /// to `false` -> RED (the late channel's words land seconds early).
    func testALateStartAndALostStretchArePaddedWithSilence() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0: UInt64 = 5_000_000_000
        let w = try PcmChannelWriter(url: url, t0: t0)
        w.append([Float](repeating: 0.1, count: 1600), atNanos: t0 + 500_000_000) // starts 0.5 s in
        XCTAssertEqual(w.samples, 8000 + 1600)
        w.append([Float](repeating: 0.1, count: 1600), atNanos: t0 + 500_000_000 + 100_000_000 + 2_000_000_000) // 2 s lost
        XCTAssertEqual(w.samples, 8000 + 1600 + 32000 + 1600)
        XCTAssertEqual(w.paddedSamples, 8000 + 32000, "the late start and the lost stretch")
        XCTAssertEqual(w.droppedSamples, 0)
        w.finish(atNanos: t0 + 4_000_000_000)
        XCTAssertEqual(w.samples, 4 * 16000)
        XCTAssertEqual(w.paddedSamples, 4 * 16000 - 1600 - 1600, "everything that is not audio is padding")
        let all = try samples(url)
        XCTAssertEqual(all.count, 4 * 16000)
        XCTAssertEqual(all[0], 0)
        XCTAssertNotEqual(all[8000], 0)
    }

    func testJitterIsNotPadded() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 0)
        w.append([Float](repeating: 0.1, count: 1600), atNanos: 0)
        w.append([Float](repeating: 0.1, count: 1600), atNanos: 100_000_000 + 40_000_000) // 40 ms late: jitter
        XCTAssertEqual(w.samples, 3200)
        XCTAssertEqual(w.paddedSamples, 0)
        XCTAssertEqual(w.droppedSamples, 0)
    }

    // MARK: a channel that runs AHEAD of the clock

    /// A chunk stamped before what is already written (overlap, a rebuilt tap)
    /// is trimmed at its head: no audio twice, position stays equal to time.
    /// Mutation: PcmChannelWriter.append, delete the `else if written - expected > Self.gapTolerance`
    /// branch -> RED (the overlap is written twice and the channel runs 0.5 s long).
    func testAChunkStampedBehindTheWrittenPositionIsTrimmedNotDuplicated() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0: UInt64 = 1_000_000_000
        let w = try PcmChannelWriter(url: url, t0: t0)
        w.append([Float](repeating: 0.1, count: 16000), atNanos: t0) // 0 ... 1 s
        w.append([Float](repeating: 0.2, count: 1600), atNanos: t0 + 500_000_000) // wholly inside what is written
        XCTAssertEqual(w.samples, 16000, "a chunk wholly behind is dropped")
        XCTAssertEqual(w.droppedSamples, 1600)
        let overlap = [Float](repeating: 0.2, count: 8000) + [Float](repeating: 0.3, count: 8000)
        w.append(overlap, atNanos: t0 + 500_000_000) // 0.5 ... 1.5 s, first half already written
        XCTAssertEqual(w.samples, 24000, "position equals time: 1.5 s")
        XCTAssertEqual(w.droppedSamples, 1600 + 8000)
        XCTAssertEqual(w.paddedSamples, 0)
        w.finish(atNanos: t0 + 1_500_000_000)
        let all = try samples(url)
        XCTAssertEqual(all.count, 24000)
        XCTAssertFalse(all.contains(6553), "0.2 is the duplicated stretch and never reaches the file")
        XCTAssertEqual(all[16000], 9830) // 0.3
        XCTAssertEqual(all[15999], 3276) // 0.1
    }

    /// Feeds `seconds` of a clock that runs `ppm` fast: a chunk every `chunk`
    /// host seconds carries `1 + ppm/1e6` times as many samples as the host
    /// time that passed.
    private func feed(_ w: PcmChannelWriter, t0: UInt64, ppm: Double, seconds: Int, chunk: Int) {
        let rate = Double(PcmChannelWriter.sampleRate) * (1 + ppm / 1e6)
        let silence = [Float](repeating: 0, count: Int(rate * Double(chunk)) + 8)
        var sent = 0
        var i = 0
        while i * chunk < seconds {
            let end = Int(Double((i + 1) * chunk) * rate)
            w.append(Array(silence[0..<(end - sent)]), atNanos: t0 + UInt64(i * chunk) * 1_000_000_000)
            sent = end
            i += 1
        }
    }

    /// A device clock 100 ppm fast gains 0.72 s over two hours; the writer's
    /// position must stay within a tolerance of the host time throughout.
    /// Mutation: same as above (the ahead branch) -> RED (final position 115.2M + 11.5k samples).
    func testAFastClockOverTwoHoursStaysAlignedToTheHostTime() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0: UInt64 = 7_000_000_000
        let w = try PcmChannelWriter(url: url, t0: t0)
        let seconds = 2 * 3600
        feed(w, t0: t0, ppm: 100, seconds: seconds, chunk: 60)
        let expected = seconds * PcmChannelWriter.sampleRate
        XCTAssertLessThanOrEqual(abs(w.samples - expected), PcmChannelWriter.gapTolerance + 200, // tolerance + one 60 s chunk's drift (96)
                                 "channel is \(w.samples - expected) samples off the host time")
        w.finish(atNanos: t0 + UInt64(seconds) * 1_000_000_000)
        XCTAssertLessThanOrEqual(abs(w.samples - expected), PcmChannelWriter.gapTolerance, "finish ends the channel at the end time")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, w.samples * 2)
    }

    /// Two writers on one t0, one clock fast and one slow: they end together.
    /// Mutation: PcmChannelWriter.append, delete the ahead branch -> RED (the fast one is ~0.4 s long).
    func testTwoDriftingChannelsEndWithinTheTolerance() throws {
        let a = tempURL(), b = tempURL()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let t0: UInt64 = 9_000_000_000
        let fast = try PcmChannelWriter(url: a, t0: t0)
        let slow = try PcmChannelWriter(url: b, t0: t0)
        let seconds = 20 * 60
        feed(fast, t0: t0, ppm: 300, seconds: seconds, chunk: 5)
        feed(slow, t0: t0, ppm: -300, seconds: seconds, chunk: 5)
        let want = seconds * PcmChannelWriter.sampleRate
        XCTAssertLessThanOrEqual(abs(fast.samples - slow.samples), 2 * PcmChannelWriter.gapTolerance, "before finish")
        XCTAssertLessThanOrEqual(abs(fast.samples - want), PcmChannelWriter.gapTolerance + 100, "fast channel before finish")
        let end = t0 + UInt64(seconds) * 1_000_000_000
        fast.finish(atNanos: end)
        slow.finish(atNanos: end)
        XCTAssertLessThanOrEqual(abs(fast.samples - slow.samples), PcmChannelWriter.gapTolerance)
        XCTAssertLessThanOrEqual(abs(fast.samples - seconds * PcmChannelWriter.sampleRate), PcmChannelWriter.gapTolerance)
    }

    /// finish never leaves an overshoot beyond the tolerance (and never pads past the end).
    /// Mutation: PcmChannelWriter.finish, delete the `written > expected` truncate -> RED.
    func testFinishCutsAnOvershootOffTheEnd() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 0)
        w.append([Float](repeating: 0.1, count: 16000), atNanos: 0)
        w.finish(atNanos: 500_000_000)
        XCTAssertEqual(w.samples, 8000)
        XCTAssertEqual(w.droppedSamples, 8000, "the overshoot cut off the end")
        let onDisk = try samples(url)
        XCTAssertEqual(onDisk.count, 8000)
    }

    // MARK: sample conversion and failures

    /// NaN is silence, not a +32767 click.
    /// Mutation: PcmChannelWriter.pcm16, drop `f.isNaN ? 0 :` -> RED.
    func testNaNBecomesSilenceAndInfinityClamps() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try PcmChannelWriter(url: url, t0: 0)
        w.append([.nan, .infinity, -.infinity, 0.5], atNanos: 0)
        w.finish(atNanos: 0)
        let onDisk = try samples(url)
        XCTAssertEqual(onDisk, [0, 32767, -32767, 16383])
    }

    /// A failed write stops the channel: the position does not advance, later
    /// appends are counted and not written.
    /// Mutation: PcmChannelWriter.append, move `written += chunk.count` before the
    /// `write` guard -> RED (position advances over a hole).
    func testAFailedWriteStopsTheChannelAndIsCounted() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let readOnly = try FileHandle(forReadingFrom: url) // every write on it fails
        let w = PcmChannelWriter(handle: readOnly, t0: 0)
        XCTAssertEqual(w.failedWrites, 0)
        w.append([Float](repeating: 0.1, count: 1600), atNanos: 0)
        XCTAssertEqual(w.failedWrites, 1)
        XCTAssertEqual(w.samples, 0, "a failed write does not advance the position")
        w.append([Float](repeating: 0.1, count: 1600), atNanos: 100_000_000)
        XCTAssertEqual(w.failedWrites, 2, "later appends are counted")
        XCTAssertEqual(w.samples, 0)
        w.finish(atNanos: 10_000_000_000)
        XCTAssertEqual(w.samples, 0, "a failed channel is not padded")
    }
}
