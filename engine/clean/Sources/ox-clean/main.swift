import Darwin
import Foundation
import OxCleanCore

// ox-clean <in.wav> <out.wav> --models DIR     one cleaning run, then exit
// ox-clean --version
// <in.wav> is mono, 48 kHz, IEEE float32. The cleaned track (same length) is written to <out.wav>.part and renamed into
// place at the end, so <out.wav> either does not exist or is whole. An existing <out.wav> or <out.wav>.part is a refusal,
// never overwritten. Nothing here opens a socket. Exit codes: OxCleanCore.ExitCode (0 ok, 1 other, 2 usage, 3 models,
// 4 input, 5 macOS < 15); a SIGINT or SIGTERM removes the .part and exits 128 + signal (Interrupt.swift).
//
// Test-only knobs, ignored unless set (the CLI contract test needs a run that is slow, or fails after N windows):
//   OX_CLEAN_TEST_SLOW_MS=<n>            sleep n ms before every window's mask
//   OX_CLEAN_TEST_FAIL_AFTER_WINDOWS=<n> the mask call number n + 1 fails with a processing error

setvbuf(stderr, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let interrupt = Interrupt()
exit(realMain(interrupt))

/// One line on stderr, the writer (if any) abandoned, then the exit. `exit` rather than a return: the explicit
/// `abandon()` is what removes the `.part`, whatever happens to the writer object afterwards.
func fail(_ code: ExitCode, _ message: String, writer: WavIO.StreamWriter? = nil) -> Never {
    writer?.abandon()
    let line = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    fputs("ox-clean: \(line)\n", stderr)
    exit(code.rawValue)
}

func realMain(_ interrupt: Interrupt) -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    if argv == ["--version"] {
        print(Pins.version)
        return ExitCode.ok.rawValue
    }
    let args: Arguments
    do { args = try Arguments.parse(argv) } catch let Arguments.Failure.usage(message) {
        fail(.usage, message)
    } catch {
        fail(.usage, "\(error)")
    }

    // Before the input, the models or anything of Core ML: macOS below the floor is a refusal, not a crash.
    if let why = Platform.refusal() { fail(.unsupportedOS, why) }

    let outPath = args.output.path
    let part = outPath + ".part"
    if let why = CLI.sameFile(args.input.path, outPath) { fail(.usage, why) }
    if CLI.exists(outPath) { fail(.failure, "\(outPath) already exists; ox-clean never overwrites an output") }
    let outDir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: outDir, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail(.failure, "the output directory \(outDir) does not exist")
    }
    if CLI.exists(part) { fail(.failure, "\(part) already exists (a run in progress, or one that was killed); remove it first") }
    interrupt.install()

    // The input: any Foundation error here is "cannot read it"; a WavIO refusal says why it is not usable.
    let wav: MappedFloatWav
    do { wav = try WavIO.readMono48k(args.input) } catch let f as WavIO.Failure {
        fail(.input, CLI.describe(f, path: args.input.path))
    } catch {
        fail(.input, "cannot read \(args.input.path): \(error.localizedDescription)")
    }

    // The models: this is where the GPU compiles its kernels (the "first prediction") and the known-answer run happens.
    let plan = ComputeChoice.current()
    let model: MaskModel
    do { model = try MaskModel(modelsDir: args.modelsDir, plan: plan) } catch let f as Failure {
        fail(f.exitCode, f.description)
    } catch {
        fail(.models, "cannot load the models from \(args.modelsDir.path): \(error.localizedDescription)")
    }

    // The output, created exclusively. Only after this succeeds may a signal unlink the .part.
    let writer: WavIO.StreamWriter
    do { writer = try WavIO.StreamWriter(url: URL(fileURLWithPath: part), sampleRate: 48_000, channels: 1) } catch let e as POSIXError
        where e.code == .EEXIST {
        fail(.failure, "\(part) already exists (a run in progress, or one that was killed); remove it first")
    } catch {
        fail(.failure, "cannot create \(part): \(error.localizedDescription)")
    }
    interrupt.arm(part: part)

    let stats: CleanStats
    do {
        stats = try Cleaner(model: TestSeam.wrap(model)).run(input: wav, output: writer)
        try writer.finish()
    } catch let f as Failure {
        fail(f.exitCode, f.description, writer: writer)
    } catch {
        // A failed write (disk full, the 4 GiB WAV limit) is the run failing, not the input being bad.
        fail(.failure, "cannot write \(part): \(CLI.message(error))", writer: writer)
    }

    // Publish: atomic and never over an existing file (RENAME_EXCL), after the point of no return for signals.
    interrupt.commit()
    if renamex_np(part, outPath, UInt32(RENAME_EXCL)) != 0 {
        let e = errno
        interrupt.disarm()
        unlink(part)
        fail(.failure, e == EEXIST ? "\(outPath) appeared while cleaning; not overwriting it"
             : "cannot move \(part) to \(outPath): \(String(cString: strerror(e)))")
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
        if slowMs > 0 { usleep(UInt32(slowMs) * 1000) }
        if let failAfter, calls >= failAfter {
            throw Failure.processing("test_seam", detail: "OX_CLEAN_TEST_FAIL_AFTER_WINDOWS: failing after \(failAfter) windows")
        }
        calls += 1
        return try inner.mask(features: features, frames: frames)
    }
}
