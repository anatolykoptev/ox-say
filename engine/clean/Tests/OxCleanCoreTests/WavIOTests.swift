import Foundation
import XCTest
@testable import OxCleanCore

/// The reader parses a file the user chose, so every length field in it is untrusted. Each refusal class below has
/// its own test; a malformed file must THROW, never trap or read outside the mapping.
final class WavIOTests: XCTestCase {
    typealias F = WavFixture
    private let x: [Float] = [0.25, -0.5, 0.75, -1, 0.125]

    private func read(_ bytes: [UInt8]) throws -> MappedFloatWav { try WavIO.readMono48k(F.write(bytes: bytes)) }
    private func failure(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> WavIO.Failure? {
        do { _ = try read(bytes); XCTFail("accepted a malformed file", file: file, line: line); return nil } catch {
            XCTAssertTrue(error is WavIO.Failure, "\(error)", file: file, line: line)
            return error as? WavIO.Failure
        }
    }
    private var good: [UInt8] { F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", F.floats(x))]) }

    // MARK: spec tests

    // Mutation: WavIO.swift sampleRate == 48000 check removed -> red.
    func testAWavThatIsNotMono48kFloatIsRefused() throws {
        let url = try WavFixture.write(rate: 44100, channels: 1, samples: [0, 0.5, -0.5])
        XCTAssertThrowsError(try WavIO.readMono48k(url)) { XCTAssertEqual($0 as? WavIO.Failure, .unsupported("sample rate 44100, need 48000")) }
        let stereo = try WavFixture.write(rate: 48000, channels: 2, samples: [0, 0, 1, 1])
        XCTAssertThrowsError(try WavIO.readMono48k(stereo)) { XCTAssertEqual($0 as? WavIO.Failure, .unsupported("2 channels, need 1")) }
    }

    // Mutations: finish() forgets the data size -> red; window() stops zero-padding -> red.
    func testWriterThenReaderRoundTripsBitExactly() throws {
        let x: [Float] = (0..<10_007).map { Float(sin(Double($0) * 0.01)) * 0.7 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID()).wav")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
        try x.withUnsafeBufferPointer { try w.append($0) }; try w.finish()
        let r = try WavIO.readMono48k(url)
        XCTAssertEqual(r.info.frames, x.count)
        XCTAssertEqual(r.window(start: 0, count: x.count), x)
        XCTAssertEqual(r.window(start: x.count - 3, count: 6).suffix(3), [0, 0, 0])   // zero-padded past the end
    }

    // MARK: refusal classes (untrusted input)

    func testNotRIFFWAVEIsNotWav() {
        XCTAssertEqual(failure([]), .notWav)
        XCTAssertEqual(failure(Array("RIFF".utf8)), .notWav)
        XCTAssertEqual(failure(Array("RIFX\0\0\0\0WAVE".utf8)), .notWav)
        XCTAssertEqual(failure(Array("RIFF\0\0\0\0AVI ".utf8)), .notWav)
        XCTAssertEqual(failure([UInt8](repeating: 0xFF, count: 64)), .notWav)
    }

    func testAMissingFileThrowsTheFilesystemError() {
        XCTAssertThrowsError(try WavIO.readMono48k(F.tmp("absent"))) { XCTAssertFalse($0 is WavIO.Failure) }
    }

    func testAMissingFmtChunkIsRefused() {
        XCTAssertEqual(failure(F.riff([F.chunk("data", F.floats(x))])), .unsupported("no fmt chunk"))
        XCTAssertEqual(failure(F.riff([])), .unsupported("no fmt chunk"))
    }

    // Mutation: the `size >= 16` guard on fmt removed -> reads past the payload.
    func testAFmtChunkShorterThanSixteenBytesIsRefused() {
        for n in [0, 1, 14, 15] {
            let short = Array(F.fmt().prefix(n))
            XCTAssertEqual(failure(F.riff([F.chunk("fmt ", short), F.chunk("data", F.floats(x))])),
                           .unsupported("fmt chunk of \(n) bytes, need at least 16"), "n=\(n)")
        }
    }

    func testAFmtChunkRunningPastTheFileIsTruncated() {
        var b = good; b.replaceSubrange(16..<20, with: F.u32(UInt32.max))
        XCTAssertEqual(failure(b), .truncated)
        b = good; b.replaceSubrange(16..<20, with: F.u32(UInt32(good.count)))
        XCTAssertEqual(failure(b), .truncated)
        XCTAssertEqual(failure(Array(good.prefix(30))), .truncated)   // cut inside fmt
    }

    // Mutation: WavIO.swift, the `end <= data.count` check on the data chunk removed -> reads out of bounds.
    func testADataSizeNearUInt32MaxIsTruncatedNotAnOverflow() {
        for size in [UInt32.max - 1, UInt32.max - 3, 0x8000_0000] {
            let b = F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", size: size, F.floats(x))])
            XCTAssertEqual(failure(b), .truncated, "size \(size)")
        }
    }

    // Fix round 8: a streaming writer (ffmpeg to a pipe) leaves 0xFFFFFFFF in the data size, and often in the RIFF size.
    // The data runs to the end of the file: whole floats only. Any other overrun stays truncated (test above).
    // Mutation: WavIO.swift, the `size == 0xFFFF_FFFF` clamp removed -> .truncated here.
    func testAStreamingWavWithAnUnknownDataSizeRunsToTheEndOfTheFile() throws {
        let stream = F.ascii("RIFF") + F.u32(UInt32.max) + F.ascii("WAVE") + F.chunk("fmt ", F.fmt()) + F.chunk("data", size: UInt32.max, F.floats(x))
        let r = try read(stream)
        XCTAssertEqual(r.info.frames, x.count)
        XCTAssertEqual(r.window(start: 0, count: x.count), x)
        let ragged = try read(F.ascii("RIFF") + F.u32(UInt32.max) + F.ascii("WAVE") + F.chunk("fmt ", F.fmt())
                              + F.chunk("data", size: UInt32.max, F.floats(x) + [1, 2, 3], pad: false))
        XCTAssertEqual(ragged.info.frames, x.count, "a partial trailing float is dropped")
        XCTAssertEqual(failure(F.ascii("RIFF") + F.u32(UInt32.max) + F.ascii("WAVE") + F.chunk("fmt ", F.fmt()) + F.chunk("data", size: UInt32.max, [1, 2, 3], pad: false)), .empty)
    }

    func testADataChunkPastTheEndOfTheFileIsTruncated() {
        // header promises 6 floats, file holds 5; and one byte short of the last float.
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", size: 24, F.floats(x))])), .truncated)
        XCTAssertEqual(failure(Array(good.dropLast())), .truncated)
        XCTAssertEqual(failure(Array(good.prefix(44))), .truncated)   // header only, size says 20
    }

    func testAnEmptyDataChunkIsEmpty() {
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", [])])), .empty)
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", [1, 2, 3])])), .empty)   // under one sample
    }

    func testAFmtWithNoDataChunkIsTruncated() {
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt())])), .truncated)
    }

    func testAHugeChunkSkippedBeforeFmtThrowsInsteadOfWrapping() {
        // Skipping a LIST chunk that claims 4 GiB lands far past the file: no fmt can follow.
        let b = F.riff([F.chunk("LIST", size: UInt32.max, [1, 2, 3, 4]), F.chunk("fmt ", F.fmt()), F.chunk("data", F.floats(x))])
        XCTAssertEqual(failure(b), .unsupported("no fmt chunk"))
        let odd = F.riff([F.chunk("LIST", size: UInt32.max - 1, [1, 2]), F.chunk("fmt ", F.fmt()), F.chunk("data", F.floats(x))])
        XCTAssertEqual(failure(odd), .unsupported("no fmt chunk"))
    }

    func testAChunkHeaderCutShortIsHandled() {
        for n in 1..<8 { XCTAssertNotNil(failure(Array(good.prefix(12)) + [UInt8](repeating: 0x41, count: n))) }
    }

    func testOtherEncodingsAreRefused() {
        let d = F.chunk("data", F.floats(x))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt(tag: 1, bits: 16)), d])), .unsupported("format tag 1, need IEEE float"))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt(tag: 3, bits: 64)), d])), .unsupported("64-bit float, need 32"))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt(tag: 3, bits: 16)), d])), .unsupported("16-bit float, need 32"))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmt(tag: 0)), d])), .unsupported("format tag 0, need IEEE float"))
    }

    // Mutation: the `blockAlign == 4` guard removed -> red.
    func testALyingBlockAlignIsRefused() {
        var f = F.fmt(); f.replaceSubrange(12..<14, with: F.u16(8))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", f), F.chunk("data", F.floats(x))])), .unsupported("block align 8, need 4"))
    }

    // MARK: well-formed shapes that must parse

    // Mutation: the odd-size pad byte ignored when stepping to the next chunk -> red.
    func testOddChunkPaddingIsSkipped() throws {
        let junk = F.chunk("LIST", [1, 2, 3])                       // 3 bytes + pad
        let r = try read(F.riff([junk, F.chunk("fmt ", F.fmt()), F.chunk("LIST", [9]), F.chunk("data", F.floats(x))]))
        XCTAssertEqual(r.window(start: 0, count: x.count), x)
        XCTAssertEqual(r.info, WavInfo(sampleRate: 48000, channels: 1, frames: 5,
                                       dataOffset: 12 + 12 + 24 + 10 + 8))
    }

    func testAnOddSizedLastChunkWithoutItsPadByteStillReads() throws {
        // a data chunk whose size is odd-padded-by-nobody is common at EOF; ours is a multiple of 4 anyway, so cut a trailing LIST
        let r = try read(F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", F.floats(x)), F.chunk("LIST", [1, 2, 3], pad: false)]))
        XCTAssertEqual(r.info.frames, 5)
    }

    func testDataBeforeFmtIsFound() throws {
        let r = try read(F.riff([F.chunk("data", F.floats(x)), F.chunk("fmt ", F.fmt())]))
        XCTAssertEqual(r.window(start: 0, count: 5), x)
    }

    func testExtensibleWithAFloatSubformatIsAccepted() throws {
        let r = try read(F.riff([F.chunk("fmt ", F.fmtExtensible(guid: F.guidIEEEFloat)), F.chunk("data", F.floats(x))]))
        XCTAssertEqual(r.window(start: 0, count: 5), x)
    }

    func testExtensibleWithAnyOtherSubformatOrAShortBodyIsRefused() {
        let d = F.chunk("data", F.floats(x))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmtExtensible(guid: F.guidPCM)), d])), .unsupported("extensible subformat is not IEEE float"))
        var wrongTail = F.guidIEEEFloat; wrongTail[15] = 0x70   // right first bytes, not Microsoft's GUID tail
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", F.fmtExtensible(guid: wrongTail)), d])), .unsupported("extensible subformat is not IEEE float"))
        let cut = Array(F.fmtExtensible(guid: F.guidIEEEFloat).prefix(30))
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", cut), d])), .unsupported("extensible fmt chunk of 30 bytes, need 40"))
        var noExt = F.fmtExtensible(guid: F.guidIEEEFloat); noExt.replaceSubrange(16..<18, with: F.u16(0))   // cbSize 0
        XCTAssertEqual(failure(F.riff([F.chunk("fmt ", noExt), d])), .unsupported("extensible cbSize 0, need at least 22"))
    }

    // MARK: window

    func testWindowIsTotalOverAnyArguments() throws {
        let r = try read(good)
        XCTAssertEqual(r.window(start: -2, count: 4), [0, 0, 0.25, -0.5])
        XCTAssertEqual(r.window(start: 3, count: 0), [])
        XCTAssertEqual(r.window(start: 3, count: -4), [])
        XCTAssertEqual(r.window(start: Int.max, count: 3), [0, 0, 0])
        XCTAssertEqual(r.window(start: Int.max - 1, count: 3), [0, 0, 0])
        XCTAssertEqual(r.window(start: Int.min, count: 3), [0, 0, 0])
        XCTAssertEqual(r.window(start: 4, count: 3), [0.125, 0, 0])
    }

    func testNonFiniteSamplesPassThroughUnchanged() throws {
        let bits: [UInt32] = [0x7FC0_0000, 0x7F80_0000, 0xFF80_0000]
        let r = try read(F.riff([F.chunk("fmt ", F.fmt()), F.chunk("data", bits.flatMap { F.u32($0) })]))
        XCTAssertEqual(r.window(start: 0, count: 3).map(\.bitPattern), bits)
    }

    // MARK: writer

    func testWriterHeaderIs44BytesWithPatchedSizes() throws {
        let url = F.tmp("hdr")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
        try x.withUnsafeBufferPointer { try w.append($0) }
        try x.withUnsafeBufferPointer { try w.append($0) }
        try w.finish()
        let b = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(b.count, 44 + 40)
        XCTAssertEqual(Array(b[0..<4]), F.ascii("RIFF"))
        XCTAssertEqual(Array(b[4..<8]), F.u32(36 + 40))
        XCTAssertEqual(Array(b[36..<40]), F.ascii("data"))
        XCTAssertEqual(Array(b[40..<44]), F.u32(40))
        XCTAssertEqual(Array(b[20..<22]), F.u16(3))
    }

    // A writer that never reached finish() removes its file: no half-written file at the output path, and a retry
    // does not hit EEXIST. Mutation: deinit's discard() removed -> red.
    func testAWriterThatNeverFinishedLeavesNoFileAndTheRetrySucceeds() throws {
        let url = F.tmp("unfinished")
        do {
            let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
            try x.withUnsafeBufferPointer { try w.append($0) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let w2 = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
        try x.withUnsafeBufferPointer { try w2.append($0) }
        try w2.finish()
        XCTAssertEqual(try WavIO.readMono48k(url).info.frames, 5)
    }

    func testAbandonRemovesTheFileAndEveryLaterCallThrows() throws {
        let url = F.tmp("abandon")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
        w.abandon(); w.abandon()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try w.finish())
        XCTAssertThrowsError(try x.withUnsafeBufferPointer { try w.append($0) })
    }

    func testAFinishedFileSurvivesDeinitAndAbandon() throws {
        let url = F.tmp("kept")
        do {
            let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
            try x.withUnsafeBufferPointer { try w.append($0) }
            try w.finish()
            w.abandon()
        }
        XCTAssertEqual(try WavIO.readMono48k(url).info.frames, 5)
    }

    // Only its own file: if the path was replaced by someone else's file, abandon leaves that alone.
    // Mutation: the dev/ino comparison in discard() dropped -> red.
    func testAbandonDoesNotRemoveAFileItDidNotCreate() throws {
        let url = F.tmp("swapped")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1)
        unlink(url.path)
        try Data([9, 9, 9]).write(to: url)
        w.abandon()
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [9, 9, 9])
        unlink(url.path)
    }

    // MARK: writer failure paths (system calls injected)

    /// Real calls, with a log of every close and optional failures.
    final class Spy: @unchecked Sendable {
        var closed: [Int32] = []
        var failWrite = false, failPwrite = false
        var ops: WavIO.FileOps {
            var o = WavIO.FileOps.posix
            o.write = { [unowned self] fd, p, n in if failWrite { errno = EIO; return -1 }; return Darwin.write(fd, p, n) }
            o.pwrite = { [unowned self] fd, p, n, off in if failPwrite { errno = EIO; return -1 }; return Darwin.pwrite(fd, p, n, off) }
            o.close = { [unowned self] fd in closed.append(fd); return Darwin.close(fd) }
            return o
        }
    }

    // Bug: the header-write failure closed the fd and deinit closed the same number again, which in a threaded
    // process can close another thread's descriptor. Mutation: closeFD/discard() stops setting `fd = -1` -> two closes.
    func testAFailedHeaderWriteClosesTheDescriptorExactlyOnceAndRemovesTheFile() throws {
        let spy = Spy(); spy.failWrite = true
        let url = F.tmp("hdrfail")
        XCTAssertThrowsError(try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1, io: spy.ops)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(spy.closed.count, 1, "closes: \(spy.closed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // And the descriptor number is really free: a fresh open gets it back and survives.
        let probe = open("/dev/null", O_RDONLY); defer { close(probe) }
        XCTAssertEqual(probe, spy.closed[0])
        XCTAssertNotEqual(fcntl(probe, F_GETFD), -1)
    }

    func testEachWriterClosesItsDescriptorExactlyOnce() throws {
        let spy = Spy()
        let url = F.tmp("once")
        do {
            let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1, io: spy.ops)
            try x.withUnsafeBufferPointer { try w.append($0) }
            try w.finish(); try w.finish()
        }
        XCTAssertEqual(spy.closed.count, 1)
        let url2 = F.tmp("once2")
        do { _ = try WavIO.StreamWriter(url: url2, sampleRate: 48000, channels: 1, io: spy.ops) }
        XCTAssertEqual(spy.closed.count, 2)
    }

    // Bug: finish() set `finished` before the pwrites, so after a failure the second call returned silently.
    // Mutation: `finishError = error` removed from finish()'s catch -> red.
    func testAFailedFinishThrowsTheSameErrorOnEveryLaterCallAndRemovesTheFile() throws {
        let spy = Spy()
        let url = F.tmp("finfail")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1, io: spy.ops)
        try x.withUnsafeBufferPointer { try w.append($0) }
        spy.failPwrite = true
        XCTAssertThrowsError(try w.finish()) { XCTAssertEqual(($0 as? POSIXError)?.code, .EIO) }
        XCTAssertThrowsError(try w.finish()) { XCTAssertEqual(($0 as? POSIXError)?.code, .EIO) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(spy.closed.count, 1)
    }

    func testAFailedAppendPoisonsTheWriterAndFinishThrows() throws {
        let spy = Spy()
        let url = F.tmp("appfail")
        let w = try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1, io: spy.ops)
        spy.failWrite = true
        XCTAssertThrowsError(try x.withUnsafeBufferPointer { try w.append($0) })
        spy.failWrite = false
        XCTAssertThrowsError(try x.withUnsafeBufferPointer { try w.append($0) })
        XCTAssertThrowsError(try w.finish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(spy.closed.count, 1)
    }

    // The 4 GiB guard in append(), driven by placing the byte counter near the limit (4 GiB of real audio is not
    // something a unit test writes). Mutation: the `wouldOverflowRIFF` guard removed from append() -> red.
    func testAppendRefusesToCrossTheFourGiBLimit() throws {
        let w = try WavIO.StreamWriter(url: F.tmp("big"), sampleRate: 48000, channels: 1)
        w.dataBytes = UInt64(UInt32.max) - 36 - 4
        XCTAssertThrowsError(try [Float(1), 2].withUnsafeBufferPointer { try w.append($0) }) {
            XCTAssertEqual($0 as? WavIO.Failure, .unsupported("output passes the 4 GiB WAV limit"))
        }
        XCTAssertEqual(w.dataBytes, UInt64(UInt32.max) - 36 - 4)   // nothing was counted
        try [Float(1)].withUnsafeBufferPointer { try w.append($0) }   // exactly up to the limit is fine
        XCTAssertEqual(w.dataBytes, UInt64(UInt32.max) - 36)
    }

    // Constraint 5: never overwrite an existing output. Mutation: O_EXCL dropped from the writer's open -> red.
    func testWriterRefusesAnExistingFileAndLeavesItUntouched() throws {
        let url = try F.write(bytes: [1, 2, 3])
        XCTAssertThrowsError(try WavIO.StreamWriter(url: url, sampleRate: 48000, channels: 1))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [1, 2, 3])
    }

    // Fix round 2: the .part is its own lock. Mutation: WavIO.swift, O_EXLOCK left out of the open flags -> red.
    func testALockedWriterCannotBeLockedByAnotherDescriptorUntilItIsDone() throws {
        func tryLock(_ url: URL) -> Int32 {
            let fd = open(url.path, O_RDONLY)
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno
        }
        let plain = F.tmp(), locked = F.tmp(), abandoned = F.tmp()
        let p = try WavIO.StreamWriter(url: plain, sampleRate: 48000, channels: 1)
        XCTAssertEqual(tryLock(plain), 0, "an ordinary writer holds no lock")
        let w = try WavIO.StreamWriter(url: locked, sampleRate: 48000, channels: 1, exclusiveLock: true)
        XCTAssertEqual(tryLock(locked), EWOULDBLOCK, "a live locked writer")
        try w.finish()
        XCTAssertEqual(tryLock(locked), 0, "finished: the lock is gone")
        let a = try WavIO.StreamWriter(url: abandoned, sampleRate: 48000, channels: 1, exclusiveLock: true)
        a.abandon()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        withExtendedLifetime(p) {}
        try? FileManager.default.removeItem(at: locked); try? FileManager.default.removeItem(at: plain)
    }

    func testWriterRejectsBadParametersAndUseAfterFinish() throws {
        XCTAssertThrowsError(try WavIO.StreamWriter(url: F.tmp(), sampleRate: 0, channels: 1))
        XCTAssertThrowsError(try WavIO.StreamWriter(url: F.tmp(), sampleRate: 48000, channels: 0))
        XCTAssertThrowsError(try WavIO.StreamWriter(url: F.tmp(), sampleRate: 48000, channels: 70_000))
        XCTAssertThrowsError(try WavIO.StreamWriter(url: URL(fileURLWithPath: "/nonexistent-dir/x.wav"), sampleRate: 48000, channels: 1))
        let w = try WavIO.StreamWriter(url: F.tmp(), sampleRate: 48000, channels: 2)
        XCTAssertThrowsError(try [1, 2, 3].withUnsafeBufferPointer { try w.append($0) })   // not a whole frame
        try w.finish()
        try w.finish()                                                                       // idempotent
        XCTAssertThrowsError(try x.withUnsafeBufferPointer { try w.append($0) })
    }

    func testTheWriterRefusesToPassTheRIFFFourGiBLimit() {
        XCTAssertFalse(WavIO.StreamWriter.wouldOverflowRIFF(dataBytes: 0, adding: 4 * 100))
        XCTAssertFalse(WavIO.StreamWriter.wouldOverflowRIFF(dataBytes: UInt64(UInt32.max) - 36 - 4, adding: 4))
        XCTAssertTrue(WavIO.StreamWriter.wouldOverflowRIFF(dataBytes: UInt64(UInt32.max) - 36 - 3, adding: 4))
        XCTAssertTrue(WavIO.StreamWriter.wouldOverflowRIFF(dataBytes: UInt64.max - 1, adding: 4))
    }
}
