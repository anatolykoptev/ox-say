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
        w.finish(atNanos: t0 + 4_000_000_000)
        XCTAssertEqual(w.samples, 4 * 16000)
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
    }
}
