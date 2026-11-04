import Foundation

#if !_endian(little)
#error("WavIO copies samples as little-endian bytes and assumes a little-endian host")
#endif

public struct WavInfo: Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var frames: Int
    /// Byte offset of the first sample from the start of the file.
    public var dataOffset: Int
}

/// A mono 48 kHz float32 WAV, mapped read-only. `readMono48k` has already proved that the samples
/// `dataOffset ..< dataOffset + 4 * frames` lie inside the mapping, which is what makes `window` safe.
/// The file must not be truncated by someone else while it is mapped (that is a SIGBUS in any mmap reader).
public struct MappedFloatWav {
    public let info: WavInfo
    private let data: Data

    init(info: WavInfo, data: Data) {
        self.info = info
        self.data = data
    }

    /// `count` samples from frame `start`; every position outside `0 ..< frames` reads as 0, whatever the arguments
    /// (a negative or huge `start` included). `count <= 0` gives `[]`. The caller owns the size of `count`.
    public func window(start: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        // Where the first wanted frame lands in `out`, and which file frame it is. `magnitude` because
        // `-Int.min` does not exist.
        var dst = 0
        var src = start
        if start < 0 {
            let skip = start.magnitude
            guard skip < UInt(count) else { return out }
            dst = Int(skip)
            src = 0
        }
        guard src < info.frames else { return out }
        let n = min(count - dst, info.frames - src)
        let base = info.dataOffset + src * 4
        data.withUnsafeBytes { raw in
            precondition(base + n * 4 <= raw.count, "window past the mapping: the parser's bounds check is broken")
            for i in 0..<n {
                out[dst + i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)))
            }
        }
        return out
    }
}

public enum WavIO {
    public enum Failure: Error, Equatable {
        /// Not a RIFF/WAVE file at all.
        case notWav
        /// A WAV this tool will not process; the sentence says why.
        case unsupported(String)
        /// A chunk size runs past the end of the file.
        case truncated
        /// No samples.
        case empty
    }

    /// Maps `url` and parses it. Throws `Failure` for a file that is not a mono 48 kHz IEEE-float WAV; a file that
    /// cannot be opened throws the underlying Foundation error.
    public static func readMono48k(_ url: URL) throws -> MappedFloatWav {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let info = try data.withUnsafeBytes { try parse($0) }
        return MappedFloatWav(info: info, data: data)
    }

    // MARK: parser (untrusted input)

    /// Every read goes through `u16`/`u32`/`tag`, which refuse an offset outside the buffer, and every chunk range
    /// is checked against `raw.count` before it is used. Sizes are 32-bit fields widened into `Int`, then added with
    /// overflow checking, so a size near `UInt32.max` is a range past the end, never a wrapped offset.
    static func parse(_ raw: UnsafeRawBufferPointer) throws -> WavInfo {
        let n = raw.count
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at <= n - 4 else { return nil }
            return Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at <= n - 2 else { return nil }
            return Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
        }
        func tag(_ at: Int, _ s: StaticString) -> Bool {
            guard at >= 0, at <= n - 4 else { return false }
            return s.withUTF8Buffer { want in (0..<4).allSatisfy { raw[at + $0] == want[$0] } }
        }
        func add(_ a: Int, _ b: Int) -> Int? {
            let (r, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : r
        }

        guard tag(0, "RIFF"), tag(8, "WAVE") else { throw Failure.notWav }

        var fmtAt: Int?, fmtSize = 0
        var dataAt: Int?, dataSize = 0
        var pos = 12
        while fmtAt == nil || dataAt == nil {
            guard let size = u32(pos + 4) else { break }       // fewer than 8 bytes left: no further chunk header
            let body = pos + 8                                  // pos <= n - 8, so this cannot overflow
            if tag(pos, "fmt ") {
                guard size >= 16 else { throw Failure.unsupported("fmt chunk of \(size) bytes, need at least 16") }
                guard let end = add(body, size), end <= n else { throw Failure.truncated }
                if fmtAt == nil { fmtAt = body; fmtSize = size }
            } else if tag(pos, "data") {
                guard let end = add(body, size), end <= n else { throw Failure.truncated }
                if dataAt == nil { dataAt = body; dataSize = size }
            }
            // Chunks are word-aligned: an odd payload is followed by one pad byte that the size does not count.
            guard let step = add(size, size & 1), let next = add(body, step), next <= n else { break }
            pos = next
        }

        guard let f = fmtAt else { throw Failure.unsupported("no fmt chunk") }
        let formatTag = u16(f)!, channels = u16(f + 2)!, rate = u32(f + 4)!, blockAlign = u16(f + 12)!, bits = u16(f + 14)!
        // The fmt payload is at least 16 bytes and inside the buffer (checked above), so those reads cannot fail.
        switch formatTag {
        case 3:
            break
        case 0xFFFE:
            guard fmtSize >= 40 else { throw Failure.unsupported("extensible fmt chunk of \(fmtSize) bytes, need 40") }
            let cb = u16(f + 16)!
            guard cb >= 22 else { throw Failure.unsupported("extensible cbSize \(cb), need at least 22") }
            // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: 00000003-0000-0010-8000-00AA00389B71.
            let ieeeFloat: [UInt8] = [3, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71]
            guard (0..<16).allSatisfy({ raw[f + 24 + $0] == ieeeFloat[$0] }) else {
                throw Failure.unsupported("extensible subformat is not IEEE float")
            }
        default:
            throw Failure.unsupported("format tag \(formatTag), need IEEE float")
        }
        guard bits == 32 else { throw Failure.unsupported("\(bits)-bit float, need 32") }
        guard rate == 48000 else { throw Failure.unsupported("sample rate \(rate), need 48000") }
        guard channels == 1 else { throw Failure.unsupported("\(channels) channels, need 1") }
        guard blockAlign == 4 else { throw Failure.unsupported("block align \(blockAlign), need 4") }

        guard let d = dataAt else { throw Failure.truncated }
        let frames = dataSize / 4
        guard frames > 0 else { throw Failure.empty }
        return WavInfo(sampleRate: rate, channels: channels, frames: frames, dataOffset: d)
    }

    // MARK: writer

    /// The system calls the writer makes, in one place so a test can make any of them fail. Production uses `.posix`.
    struct FileOps: Sendable {
        var open: @Sendable (String, Int32, mode_t) -> Int32
        var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
        var pwrite: @Sendable (Int32, UnsafeRawPointer, Int, off_t) -> Int
        var close: @Sendable (Int32) -> Int32
        static let posix = FileOps(
            open: { Darwin.open($0, $1, $2) }, write: { Darwin.write($0, $1, $2) },
            pwrite: { Darwin.pwrite($0, $1, $2, $3) }, close: { Darwin.close($0) })
    }

    /// Streams float32 samples into a canonical 44-byte-header WAV, so memory stays flat however long the audio is.
    /// The file is created exclusively: an existing path is an error, never overwritten. The sizes in the header
    /// start at 0 and are patched by `finish()`.
    ///
    /// A writer that does not reach a successful `finish()` (it was abandoned, deinitialised, or a write failed)
    /// removes the file it created, so a half-written file never sits at the output path and a retry does not hit
    /// EEXIST. It removes only its own file: the path is unlinked only if it still names the inode this writer
    /// created. One owner closes the descriptor: `closeFD()`, which is idempotent.
    public final class StreamWriter {
        private let io: FileOps
        private let path: String
        private let identity: (dev: dev_t, ino: ino_t)
        private var fd: Int32
        private let channels: Int
        /// Internal for tests (to place the counter near the 4 GiB limit).
        var dataBytes: UInt64 = 0
        private var finished = false
        /// Set only when finish() fully succeeded: from then on the file is the caller's and is never removed.
        private var completed = false
        private var finishError: Error?
        private var broken: Error?

        public convenience init(url: URL, sampleRate: Int, channels: Int) throws {
            try self.init(url: url, sampleRate: sampleRate, channels: channels, io: .posix)
        }

        init(url: URL, sampleRate: Int, channels: Int, io: FileOps) throws {
            guard (1...Int(UInt16.max)).contains(channels) else { throw Failure.unsupported("\(channels) channels") }
            guard sampleRate >= 1, sampleRate <= Int(UInt32.max) else { throw Failure.unsupported("sample rate \(sampleRate)") }
            let (perFrame, o1) = channels.multipliedReportingOverflow(by: 4)
            let (byteRate, o2) = sampleRate.multipliedReportingOverflow(by: perFrame)
            guard !o1, !o2, byteRate <= Int(UInt32.max), perFrame <= Int(UInt16.max) else {
                throw Failure.unsupported("\(sampleRate) Hz x \(channels) channels does not fit a WAV header")
            }
            let fd = io.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                let e = errno
                _ = io.close(fd)
                unlink(url.path)
                throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
            }
            self.io = io
            self.path = url.path
            self.identity = (st.st_dev, st.st_ino)
            self.fd = fd
            self.channels = channels

            func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
            func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
            let header = Array("RIFF".utf8) + le32(36) + Array("WAVE".utf8)
                + Array("fmt ".utf8) + le32(16) + le16(3) + le16(channels) + le32(sampleRate) + le32(byteRate)
                + le16(perFrame) + le16(32)
                + Array("data".utf8) + le32(0)
            do {
                try header.withUnsafeBytes { try writeAll($0) }
            } catch {
                // The object is fully initialised here, so deinit runs after this throw: `discard()` closes the
                // descriptor once and deinit's own call finds it already released.
                discard()
                throw error
            }
        }

        deinit { discard() }

        public func append(_ samples: UnsafeBufferPointer<Float>) throws {
            guard !finished else { throw Failure.unsupported("writer already finished") }
            if let broken { throw broken }
            guard samples.count % channels == 0 else { throw Failure.unsupported("\(samples.count) samples is not a whole number of \(channels)-channel frames") }
            guard samples.count > 0 else { return }
            let bytes = samples.count * 4
            guard !Self.wouldOverflowRIFF(dataBytes: dataBytes, adding: bytes) else { throw Failure.unsupported("output passes the 4 GiB WAV limit") }
            do {
                try writeAll(UnsafeRawBufferPointer(samples))
            } catch {
                broken = error
                discard()
                throw error
            }
            dataBytes += UInt64(bytes)
        }

        /// Patches the two size fields and closes the file. After a failure (this call's or an earlier append's)
        /// the file is removed and every later call throws the same error; after a success later calls return.
        public func finish() throws {
            if finished {
                if let finishError { throw finishError }
                return
            }
            finished = true
            do {
                if let broken { throw broken }
                func le32(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
                for (offset, value) in [(4, 36 + dataBytes), (40, dataBytes)] {
                    let b = le32(value)
                    guard io.pwrite(fd, b, 4, off_t(offset)) == 4 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
                let f = fd
                fd = -1
                guard io.close(f) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                completed = true
            } catch {
                finishError = error
                discard()
                throw error
            }
        }

        /// Gives up: closes the descriptor and removes the file this writer created. No-op after a successful
        /// `finish()`. Idempotent.
        public func abandon() {
            guard !completed else { return }
            finished = true
            if finishError == nil { finishError = Failure.unsupported("writer abandoned") }
            discard()
        }

        /// Closes the descriptor (once) and removes our file if it is still the one at `path`. A no-op after a
        /// successful finish.
        private func discard() {
            guard !completed else { return }
            if fd >= 0 {
                _ = io.close(fd)
                fd = -1
            }
            var st = stat()
            if stat(path, &st) == 0, st.st_dev == identity.dev, st.st_ino == identity.ino { unlink(path) }
        }

        /// True when `adding` more bytes would push the RIFF size field (36 + data) past `UInt32.max`.
        static func wouldOverflowRIFF(dataBytes: UInt64, adding: Int) -> Bool {
            let (total, overflow) = dataBytes.addingReportingOverflow(UInt64(adding))
            return overflow || total > UInt64(UInt32.max) - 36
        }

        private func writeAll(_ buf: UnsafeRawBufferPointer) throws {
            var done = 0
            while done < buf.count {
                let r = io.write(fd, buf.baseAddress! + done, buf.count - done)
                if r < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                done += r
            }
        }
    }
}
