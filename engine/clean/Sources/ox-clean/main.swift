import Darwin
import Foundation
import OxCleanCore

// ox-clean <in.wav> <out.wav> --models DIR     one cleaning run, then exit   (--models may sit anywhere; `--` ends options)
// ox-clean --version
// <in.wav> is a regular file: mono, 48 kHz, IEEE float32 (a streaming header with the size 0xFFFFFFFF is read to the end
// of the file). The cleaned track (same length) is written to <out.wav>.part and renamed into place at the end, so
// <out.wav> either does not exist or is whole. Where the volume has no exclusive rename (exFAT) the .part is copied to
// a hidden <dir>/.<out.wav>.copy first and that is renamed into place, so even a SIGKILL or a power cut during the copy
// leaves no truncated file under the final name. Nothing here opens a socket.
//
// Exit codes (OxCleanCore.ExitCode); the last stderr line always ends in [reason=<token>]:
//   0 ok (a silent input too)          1 anything else (processing: the model, the pipeline, a failed write)
//   2 usage, or out names the input    3 models: missing, unreadable, contract, gpu, dtype, known-answer failure
//   4 input: not a regular file, missing, empty, not mono-48k-float, non-finite, short read, unreadable
//   5 macOS < 15
//   6 output: <out> exists, another run holds <out>.part, the output directory is missing / not a directory / not
//     writable, <out> is spelled as a directory, or the destination cannot take the file (even by copy). A full disk is
//     always 6 [reason=disk_full]: refused up front when the free space cannot hold the result, and mapped to the same
//     code when the disk fills mid-write or mid-copy (#474)
//   128 + n   SIGINT, SIGTERM, SIGHUP or SIGQUIT: the .part is removed (Interrupt.swift)
//
// The .part is its own lock. It is created with O_EXCL and an exclusive flock that lasts as long as the run (the kernel
// drops it if the process dies). A run that finds a .part tries the lock: if it gets it, the .part is a leftover of a
// killed run (it must start like a WAV this tool writes) and is removed; if not, a live run owns it and this one stops.
//
// Test-only knobs, ignored unless set (the CLI contract test needs a run that is slow, or fails after N windows):
//   OX_CLEAN_TEST_SLOW_MS=<n>            sleep n ms before every window's mask
//   OX_CLEAN_TEST_FAIL_AFTER_WINDOWS=<n> the mask call number n + 1 fails with a processing error
//   OX_CLEAN_TEST_FREE_BYTES=<n>         the free-space check sees n bytes instead of the volume's
//   OX_CLEAN_TEST_SLOW_COPY_MS=<n>       sleep n ms after every megabyte copied by the exFAT publish

setvbuf(stderr, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let interrupt = Interrupt()
exit(realMain(interrupt))

/// One line on stderr (`ox-clean: <message> [reason=<token>]`), the writer (if any) abandoned, then the exit. `exit`
/// rather than a return: the explicit `abandon()` is what removes the `.part`, whatever happens to the writer object.
func fail(_ code: ExitCode, _ reason: String, _ message: String, writer: WavIO.StreamWriter? = nil) -> Never {
    writer?.abandon()
    let line = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    fputs("ox-clean: \(line) [reason=\(reason)]\n", stderr)
    exit(code.rawValue)
}

func fail(_ f: Failure, writer: WavIO.StreamWriter? = nil) -> Never {
    fail(f.exitCode, f.reason, f.description, writer: writer)
}

func realMain(_ interrupt: Interrupt) -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    if argv == ["--version"] {
        print(Pins.version)
        return ExitCode.ok.rawValue
    }
    let args: Arguments
    do { args = try Arguments.parse(argv) } catch let Arguments.Failure.usage(message) {
        fail(.usage, "usage", message)
    } catch {
        fail(.usage, "usage", "\(error)")
    }

    // Before the input, the models or anything of Core ML: macOS below the floor is a refusal, not a crash.
    if let why = Platform.refusal() { fail(.unsupportedOS, "os_too_old", why) }

    // Everything about the output that can be known without reading the input, so a bad destination costs milliseconds.
    let outPath = args.output.path
    let part = outPath + ".part"
    if args.outputIsDirectoryPath { fail(.output, "out_is_directory", "\(outPath) is spelled as a directory; give a file name for the output") }
    if let why = CLI.sameFile(args.input.path, outPath) { fail(.usage, "same_file", why) }
    if CLI.exists(outPath) { fail(.output, "out_exists", "\(outPath) already exists; ox-clean never overwrites an output") }
    let outDir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    var st = stat()
    guard stat(outDir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
        fail(.output, "output_dir", "the output directory \(outDir) does not exist or is not a directory")
    }
    guard access(outDir, W_OK | X_OK) == 0 else { fail(.output, "not_writable", "the output directory \(outDir) is not writable") }
    interrupt.install()

    // The input: a regular file (a FIFO would block, /dev/zero never ends), mono 48 kHz float.
    let inPath = args.input.path
    var ist = stat()
    if stat(inPath, &ist) != 0 {
        fail(.input, "input_unreadable", "cannot read \(inPath): \(String(cString: strerror(errno)))")
    }
    guard ist.st_mode & S_IFMT == S_IFREG else { fail(.input, "not_regular", "\(inPath) is not a regular file") }
    let wav: MappedFloatWav
    do { wav = try WavIO.readMono48k(args.input) } catch let f as WavIO.Failure {
        fail(.input, CLI.token(f), CLI.describe(f, path: inPath))
    } catch {
        fail(.input, "input_unreadable", "cannot read \(inPath): \(error.localizedDescription)")
    }

    // The disk, before the slow model load: the .part (and, without an exclusive rename, the copy beside it) must fit.
    if let why = CLI.spaceRefusal(dir: outDir, frames: wav.info.frames) { fail(.output, "disk_full", why) }

    // The output, created exclusively and locked, BEFORE the slow model load: a destination that cannot work fails now.
    // Only after this succeeds may a signal unlink the .part.
    let writer = CLI.createPart(part)
    interrupt.arm(part: part)

    // The models: this is where the GPU compiles its kernels (the "first prediction") and the known-answer run happens.
    let plan = ComputeChoice.current()
    let model: MaskModel
    do { model = try MaskModel(modelsDir: args.modelsDir, plan: plan) } catch let f as Failure {
        fail(f, writer: writer)
    } catch {
        fail(.models, "load", "cannot load the models from \(args.modelsDir.path): \(error.localizedDescription)", writer: writer)
    }

    let stats: CleanStats
    do {
        stats = try Cleaner(model: TestSeam.wrap(model)).run(input: wav, output: writer)
        try writer.finish()
    } catch let f as Failure {
        fail(f, writer: writer)
    } catch {
        // A full disk is an output problem (6), here as in the copy; any other failed write (the 4 GiB WAV limit) is the run failing.
        if CLI.isDiskFull(error) { fail(.output, "disk_full", "the disk is full: cannot write \(part)", writer: writer) }
        fail(.failure, "write_failed", "cannot write \(part): \(CLI.message(error))", writer: writer)
    }

    // Publish: atomic and never over an existing file (RENAME_EXCL), after the point of no return for signals.
    interrupt.commit()
    if renamex_np(part, outPath, UInt32(RENAME_EXCL)) != 0 {
        let e = errno
        if e == ENOTSUP || e == EOPNOTSUPP {
            // exFAT and other filesystems without exclusive rename: create the output exclusively and copy.
            if let why = CLI.publishByCopy(part: part, out: outPath) {
                interrupt.disarm()
                fail(.output, why.reason, why.message)
            }
        } else {
            interrupt.disarm()
            unlink(part)
            if e == EEXIST { fail(.output, "out_exists", "\(outPath) appeared while cleaning; not overwriting it") }
            fail(.output, "publish_failed", "cannot move \(part) to \(outPath): \(String(cString: strerror(e)))")
        }
    }

    let seconds = Double(wav.info.frames) / 48_000
    fputs(CLI.statsLine(audioSeconds: seconds, run: stats, model: model.stats, floor: SpeedFloor.floor(for: plan)) + "\n", stderr)
    return ExitCode.ok.rawValue
}

enum CLI {
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// A reason when `out` names the input: the same path after resolving symlinks and `..`, or the same inode
    /// (a hard link, a path through a different mount alias). Nil when they differ or the output does not exist yet.
    static func sameFile(_ input: String, _ output: String) -> String? {
        let a = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath().path
        if a == b { return "the output is the input (\(input)); refusing to overwrite it" }
        var si = stat(), so = stat()
        if stat(input, &si) == 0, stat(output, &so) == 0, si.st_dev == so.st_dev, si.st_ino == so.st_ino {
            return "the output \(output) is the same file as the input \(input) (a link); refusing to overwrite it"
        }
        return nil
    }

    // MARK: the .part as a lock

    enum Leftover { case none, removed, live, foreign, unverifiable }

    /// What to do about an existing `part`: nothing; it was a killed run's leftover and is now gone; a live run holds it;
    /// it is not ours (does not start like a WAV this tool writes); or the filesystem cannot say whether it is held.
    /// The leftover is removed only while this process holds its lock AND the path still names the file that was locked,
    /// so two new runs reclaiming one leftover cannot delete each other's fresh `.part`.
    static func reclaim(_ part: String) -> Leftover {
        let fd = open(part, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return errno == ENOENT ? .none : .unverifiable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return .foreign }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK ? .live : .unverifiable }
        var head = [UInt8](repeating: 0, count: 12)
        guard st.st_size >= 44, pread(fd, &head, 12, 0) == 12, Array(head[0..<4]) == Array("RIFF".utf8),
              Array(head[8..<12]) == Array("WAVE".utf8) else { return .foreign }
        var now = stat()
        guard stat(part, &now) == 0, now.st_dev == st.st_dev, now.st_ino == st.st_ino else { return .none }
        return unlink(part) == 0 ? .removed : .unverifiable
    }

    /// Creates `part` exclusively and locked; a leftover is cleared first. Exits 6 when that cannot be done.
    static func createPart(_ part: String) -> WavIO.StreamWriter {
        for _ in 0..<4 {
            switch reclaim(part) {
            case .none, .removed: break
            case .live: fail(.output, "part_live", "\(part) is held by a running ox-clean; wait for it or choose another output")
            case .foreign: fail(.output, "part_foreign", "\(part) exists and is not a partial output of ox-clean; not touching it")
            case .unverifiable: fail(.output, "part_unverifiable", "\(part) exists and this filesystem cannot say whether a run holds it; remove it by hand")
            }
            do { return try WavIO.StreamWriter(url: URL(fileURLWithPath: part), sampleRate: 48_000, channels: 1, exclusiveLock: true) } catch let e as POSIXError {
                if e.code == .EEXIST { continue }   // another run created it between our check and our create: look again
                fail(.output, "not_writable", "cannot create \(part): \(String(cString: strerror(e.code.rawValue)))")
            } catch {
                fail(.output, "not_writable", "cannot create \(part): \(error.localizedDescription)")
            }
        }
        fail(.output, "part_live", "\(part) keeps being recreated by another ox-clean; try again")
    }

    // MARK: disk space

    static func isDiskFull(_ error: Error) -> Bool {
        guard let e = error as? POSIXError else { return false }
        return e.code == .ENOSPC || e.code == .EDQUOT
    }

    /// Whether the volume under `dir` has an exclusive rename (APFS, HFS+: yes; exFAT, FAT: no).
    static func hasExclusiveRename(dir: String) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var buf = [UInt8](repeating: 0, count: 256)
        guard getattrlist(dir, &list, &buf, buf.count, 0) == 0 else { return true }   // cannot tell: the copy room is only asked for when we know
        // layout: u32 length, vol_capabilities_attr_t { u32 capabilities[4]; u32 valid[4] }
        let caps = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + 4, as: UInt32.self) }   // capabilities[VOL_CAPABILITIES_INTERFACES]
        let valid = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + 16 + 4, as: UInt32.self) }
        let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
        return valid & bit == 0 || caps & bit != 0
    }

    static func freeBytes(dir: String) -> Int64? {
        if let v = ProcessInfo.processInfo.environment["OX_CLEAN_TEST_FREE_BYTES"].flatMap({ Int64($0) }) { return v }
        var fs = statfs()
        guard statfs(dir, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// A refusal sentence when the free space under `dir` cannot hold the result (44-byte header + 4 bytes a frame), plus a
    /// second copy of it where the volume has no exclusive rename and the publish is a copy. Nil when it fits or cannot be read.
    static func spaceRefusal(dir: String, frames: Int) -> String? {
        let one = Int64(frames) * 4 + 44
        let needed = hasExclusiveRename(dir: dir) ? one : 2 * one
        guard let free = freeBytes(dir: dir), free < needed else { return nil }
        func mb(_ n: Int64) -> String { String(format: "%.1f", Double(n) / 1_048_576) }
        return "the disk is full: \(dir) has \(mb(free)) MB free and the result needs \(mb(needed)) MB"
    }

    // MARK: publishing without RENAME_EXCL

    struct PublishFailure { var reason: String; var message: String }

    /// Filesystems that answer ENOTSUP to an exclusive rename: copy the `.part` to a hidden temp name in the same
    /// directory, flush it to the drive (F_FULLFSYNC), then rename it onto `out`, so `out` is whole or absent whatever kills the process (the temp
    /// is the only thing a SIGKILL leaves, and the next run clears it). Never overwrites: `out` is checked right before the
    /// rename (the one thing a volume without RENAME_EXCL cannot make atomic; the window is microseconds). On any failure
    /// the temp and the `.part` are removed. Nil on success.
    static func publishByCopy(part: String, out: String) -> PublishFailure? {
        let url = URL(fileURLWithPath: out)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".copy").path
        func fail(_ e: Int32, _ what: String) -> PublishFailure {
            PublishFailure(reason: e == ENOSPC || e == EDQUOT ? "disk_full" : "publish_failed",
                           message: e == ENOSPC || e == EDQUOT ? "the disk is full: cannot copy \(part) to \(out)"
                               : "cannot \(what): \(String(cString: strerror(e)))")
        }
        if exists(out) { unlink(part); return PublishFailure(reason: "out_exists", message: "\(out) appeared while cleaning; not overwriting it") }
        unlink(tmp)   // a leftover of a killed copy; this run owns the .part, so it owns this name too
        let ofd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard ofd >= 0 else { let e = errno; unlink(part); return fail(e, "create \(tmp)") }
        func undo(_ e: Int32, _ what: String) -> PublishFailure {
            close(ofd)
            unlink(tmp)
            unlink(part)
            return fail(e, what)
        }
        let ifd = open(part, O_RDONLY | O_CLOEXEC)
        guard ifd >= 0 else { return undo(errno, "copy \(part) to \(out)") }
        defer { close(ifd) }
        let slowMs = min(max(ProcessInfo.processInfo.environment["OX_CLEAN_TEST_SLOW_COPY_MS"].flatMap { Int($0) } ?? 0, 0), 60_000)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(ifd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return undo(errno, "copy \(part) to \(out)") }
            if n == 0 { break }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { write(ofd, $0.baseAddress! + done, n - done) }
                if w < 0 { if errno == EINTR { continue }; return undo(errno, "copy \(part) to \(out)") }
                done += w
            }
            if slowMs > 0 { usleep(UInt32(slowMs) * 1000) }
        }
        // F_FULLFSYNC: on macOS fsync leaves the data in the drive's cache, so a power cut could still lose the copy that
        // the rename is about to publish. Volumes that cannot do it fall back to fsync.
        guard fcntl(ofd, F_FULLFSYNC) == 0 || fsync(ofd) == 0 else { return undo(errno, "copy \(part) to \(out)") }
        guard close(ofd) == 0 else { let e = errno; unlink(tmp); unlink(part); return fail(e, "finish \(out)") }
        if exists(out) { unlink(tmp); unlink(part); return PublishFailure(reason: "out_exists", message: "\(out) appeared while cleaning; not overwriting it") }
        guard rename(tmp, out) == 0 else { let e = errno; unlink(tmp); unlink(part); return fail(e, "move \(tmp) to \(out)") }
        unlink(part)
        return nil
    }

    // MARK: messages

    static func token(_ f: WavIO.Failure) -> String {
        switch f {
        case .notWav: return "not_wav"
        case .unsupported: return "unsupported_format"
        case .truncated: return "truncated"
        case .empty: return "empty"
        }
    }

    static func describe(_ f: WavIO.Failure, path: String) -> String {
        switch f {
        case .notWav: return "\(path) is not a WAV file"
        case .unsupported(let why): return "\(path) cannot be cleaned: \(why) (need mono, 48000 Hz, 32-bit float)"
        case .truncated: return "\(path) is truncated: a chunk runs past the end of the file"
        case .empty: return "\(path) holds no audio"
        }
    }

    static func message(_ error: Error) -> String {
        if let e = error as? WavIO.Failure { return describe(e, path: "output") }
        return error.localizedDescription
    }

    /// `ox-clean: 123.4 s audio in 0.7 s (172.8x), load 1.7 s, first prediction 5.7 s, units cpuAndGPU, device Apple M5 Pro, floor 50x`
    static func statsLine(audioSeconds: Double, run: CleanStats, model: ModelStats, floor: Double) -> String {
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        let speed = run.totalSeconds > 0 ? audioSeconds / run.totalSeconds : 0
        return "ox-clean: \(f1(audioSeconds)) s audio in \(f1(run.totalSeconds)) s (\(f1(speed))x), load \(f1(model.loadSeconds)) s, "
            + "first prediction \(f1(model.firstPredictionSeconds)) s, units \(model.computeUnits ?? "none"), "
            + "device \(model.deviceName ?? "none"), floor \(String(format: "%g", floor))x"
    }
}
/// The two environment knobs of the contract test (see the header). With neither set the model is returned as is.
final class TestSeam: MaskPredicting, @unchecked Sendable {
    private let inner: MaskPredicting
    private let slowMs: Int
    private let failAfter: Int?
    private var calls = 0

    static func wrap(_ model: MaskPredicting) -> MaskPredicting {
        let env = ProcessInfo.processInfo.environment
        let slow = env["OX_CLEAN_TEST_SLOW_MS"].flatMap { Int($0) } ?? 0
        let fail = env["OX_CLEAN_TEST_FAIL_AFTER_WINDOWS"].flatMap { Int($0) }
        guard slow > 0 || fail != nil else { return model }
        return TestSeam(inner: model, slowMs: slow, failAfter: fail)
    }

    private init(inner: MaskPredicting, slowMs: Int, failAfter: Int?) {
        self.inner = inner
        self.slowMs = slowMs
        self.failAfter = failAfter
    }

    func mask(features: [Float], frames: Int) throws -> [Float] {
        if slowMs > 0 { usleep(UInt32(min(slowMs, 60_000)) * 1000) }
        if let failAfter, calls >= failAfter {
            throw Failure.processing("test_seam", detail: "OX_CLEAN_TEST_FAIL_AFTER_WINDOWS: failing after \(failAfter) windows")
        }
        calls += 1
        return try inner.mask(features: features, frames: frames)
    }
}
