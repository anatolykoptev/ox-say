import Foundation
import Testing
@testable import OxDiarCore

private func pcmFile(_ samples: [Int16]) throws -> URL {
    var data = Data()
    for s in samples { var v = s.littleEndian; data.append(Data(bytes: &v, count: 2)) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ox-diar-src-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

@Suite struct MappedPCM16SourceTests {
    @Test func samplesAreSignedLittleEndianAndScaled() throws {
        let url = try pcmFile([0, 16384, -32768])
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MappedPCM16Source(contentsOf: url)
        #expect(source.sampleCount == 3)
        var buf = [Float](repeating: 0, count: 3)
        try buf.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: 0, count: 3) }
        #expect(buf == [0, 0.5, -1])
    }

    @Test func readingPastTheEndCopiesWhatExistsAndLeavesTheRest() throws {
        let url = try pcmFile([0, 16384, -32768])
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MappedPCM16Source(contentsOf: url)
        var buf = [Float](repeating: 7, count: 5)
        try buf.withUnsafeMutableBufferPointer { try source.copySamples(into: $0.baseAddress!, offset: 2, count: 5) }
        #expect(buf == [-1, 7, 7, 7, 7])
    }

    @Test func anEmptyFileIsEmptyAndAMissingOneUnreadable() throws {
        let url = try pcmFile([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PCMError.empty) { try MappedPCM16Source(contentsOf: url) }
        #expect(throws: PCMError.unreadable) {
            try MappedPCM16Source(contentsOf: URL(fileURLWithPath: "/nonexistent/ox-diar-src.pcm"))
        }
    }
}

@Suite struct ChunkFeederTests {
    @Test func theTailChunkIsShorterAndTheConcatenationIsTheSource() throws {
        let url = try pcmFile((0..<25).map { Int16($0 * 1000) })
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try MappedPCM16Source(contentsOf: url)
        var sizes: [Int] = []
        var all: [Float] = []
        try ChunkFeeder.feed(source: source, chunkSamples: 10) { chunk in
            sizes.append(chunk.count)
            all.append(contentsOf: chunk)
        }
        #expect(sizes == [10, 10, 5])
        #expect(all == (0..<25).map { Float($0 * 1000) / 32768 })
    }
}
