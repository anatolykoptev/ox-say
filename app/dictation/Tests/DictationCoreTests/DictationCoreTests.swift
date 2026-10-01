import XCTest
@testable import DictationCore

/// A pasteboard that behaves like NSPasteboard: every write bumps changeCount.
/// An item is its declared types in order; a nil data slot is a type whose
/// data cannot be had without materialising it — a promise or a failed read.
final class FakePasteboard: DictationPasteboard {
    var items: [[(type: String, data: Data?)]]
    private(set) var changeCount = 0
    /// Every type `data(item:forType:)` was asked for: a promised type must
    /// never show up here, because reading one runs the source app's provider.
    private(set) var reads: [String] = []

    init(text: String) { items = [[("public.utf8-plain-text", Data(text.utf8))]] }

    var declaredItems: [[String]] { items.map { $0.map(\.type) } }

    func data(item index: Int, forType type: String) -> Data? {
        reads.append(type)
        return items[index].first { $0.type == type }?.data ?? nil
    }

    @discardableResult func writeText(_ text: String) -> Int {
        items = [[("public.utf8-plain-text", Data(text.utf8))]]
        changeCount += 1
        return changeCount
    }

    /// Like SystemPasteboard.restore: the markers go on every item put back,
    /// after its own types.
    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items.map { entries in
            entries.map { ($0.type, $0.data as Data?) }
                + PasteboardMarker.restored.map { ($0, Data()) }
        }
        changeCount += 1
    }

    /// The user (or another app) copies something.
    func userCopies(_ text: String) { writeText(text) }
    var text: String {
        String(decoding: items.first?.first { $0.type == "public.utf8-plain-text" }?.data ?? Data(), as: UTF8.self)
    }
}

final class ClipboardLeaseTests: XCTestCase {
    func testRestoresTheOriginalWhenNobodyWroteMeanwhile() {
        let board = FakePasteboard(text: "the user's copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertEqual(board.text, "dictated text", "the text must be on the clipboard for the paste")
        XCTAssertTrue(lease.release())
        XCTAssertEqual(board.text, "the user's copy")
    }

    // Mutation: drop the `board.changeCount == ourChange` guard in
    // ClipboardLease.release -> RED (the user's newer copy is overwritten).
    func testKeepsANewerCopyTheUserMadeMeanwhile() {
        let board = FakePasteboard(text: "old copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        board.userCopies("new copy made during dictation")
        XCTAssertFalse(lease.release())
        XCTAssertEqual(board.text, "new copy made during dictation")
    }

    // Mutation: delete `guard !original.isSensitive else { return false }` in
    // ClipboardLease.release -> RED (the password goes back on the clipboard and
    // outlives the password manager's auto-clear).
    func testAPasswordManagersCopyIsNotPutBack() {
        let board = FakePasteboard(text: "hunter2")
        board.items[0].append((type: PasteboardMarker.concealed, data: Data()))
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertEqual(board.text, "dictated text")
    }

    // Mutation: add `transient` to PasteboardMarker.restored and to
    // PasteboardMarker.sensitive (the bug the review reproduced: restore marked
    // the copy Transient, and Transient counted as sensitive) -> RED here.
    func testTwoDictationsInARowBothGiveTheClipboardBack() {
        let board = FakePasteboard(text: "the user's copy")
        XCTAssertTrue(ClipboardLease(board: board, text: "first").release())
        XCTAssertTrue(ClipboardLease(board: board, text: "second").release())
        XCTAssertEqual(board.text, "the user's copy")
        XCTAssertTrue(Set(PasteboardMarker.restored).isDisjoint(with: PasteboardMarker.sensitive))
    }

    func testReleaseActsOnce() {
        let board = FakePasteboard(text: "a")
        let lease = ClipboardLease(board: board, text: "b")
        XCTAssertTrue(lease.release())
        board.userCopies("c")
        XCTAssertFalse(lease.release())
        XCTAssertEqual(board.text, "c")
    }

    // Mutation: in PasteboardSnapshot.capture store the types in a dictionary
    // again -> RED (the order readers pick formats by is lost on restore).
    func testTypeOrderSurvivesTheRoundTrip() {
        let board = FakePasteboard(text: "")
        board.items = [[
            ("public.rtf", Data("rich".utf8)),
            ("public.utf8-plain-text", Data("plain".utf8)),
            ("public.html", Data("<b>".utf8)),
            ("com.apple.icns", Data(repeating: 1, count: 4)),
        ]]
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertTrue(lease.release())
        XCTAssertEqual(
            board.items[0].map(\.type),
            ["public.rtf", "public.utf8-plain-text", "public.html", "com.apple.icns",
             PasteboardMarker.autoGenerated],
            "the restored item must keep the declared type order")
    }

    // Mutation: drop the promised-type check in PasteboardSnapshot.capture ->
    // RED (the promise is read here — which on NSPasteboard runs the source
    // app's provider on the main thread — and the snapshot goes back).
    func testAPromisedTypeIsNotReadAndTheClipboardIsNotRestored() {
        let board = FakePasteboard(text: "the user's file")
        board.items[0].append((type: "com.apple.pasteboard.promised-file", data: nil))
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertFalse(board.reads.contains("com.apple.pasteboard.promised-file"),
                       "a promised type must never be materialised to snapshot it")
        XCTAssertNotNil(lease.notice, "the user must hear the clipboard was not put back")
        XCTAssertEqual(board.text, "dictated text",
                       "a partial restore is not the user's copy: nothing is put back")
    }

    // Mutation: drop the maxBytes check in PasteboardSnapshot.capture -> RED
    // (a huge clipboard is held for a restore that then happens silently).
    func testAClipboardOverTheSizeCapIsNotRestored() {
        let board = FakePasteboard(text: "")
        board.items = [[("public.png", Data(repeating: 0, count: PasteboardSnapshot.maxBytes + 1))]]
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertNotNil(lease.notice)
        XCTAssertEqual(board.text, "dictated text")
    }

    // Mutation: treat a type with no data as a problem in
    // PasteboardSnapshot.capture -> RED (the whole clipboard would be thrown
    // away over a type no app can paste anyway).
    func testATypeWithNoDataDoesNotCostTheRestOfTheClipboard() {
        let board = FakePasteboard(text: "")
        board.items = [[("public.utf8-plain-text", Data("copy".utf8)), ("public.tiff", nil)]]
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertTrue(lease.release())
        XCTAssertNil(lease.notice)
        XCTAssertEqual(board.text, "copy")
    }

    func testTheNoticeNamesEachProblemOnce() {
        let board = FakePasteboard(text: "")
        board.items = [
            [("com.apple.pasteboard.promised-file-url", nil), ("com.apple.NSFilePromiseItemMetaData", nil)],
            [("com.apple.pasteboard.promised-file", nil)],
        ]
        let lease = ClipboardLease(board: board, text: "dictated text")
        XCTAssertFalse(lease.release())
        XCTAssertEqual(lease.notice,
                       "The earlier clipboard was not put back: it held a promised file. The dictated text is on the clipboard.")
    }

    func testAClipboardSomeoneElseWroteToNeedsNoNotice() {
        let board = FakePasteboard(text: "old copy")
        let lease = ClipboardLease(board: board, text: "dictated text")
        board.userCopies("new copy made during dictation")
        XCTAssertFalse(lease.release())
        XCTAssertNil(lease.notice, "the clipboard holds the user's own copy: nothing was lost")
    }
}

final class OutputPolicyTests: XCTestCase {
    // Mutation: ignore `secureInput` in OutputPolicy.decide -> RED (the text
    // would be pasted into a password field).
    func testNeverPastesIntoAPasswordField() {
        guard case .clipboardOnly = OutputPolicy.decide(secureInput: true, accessibilityTrusted: true) else {
            return XCTFail("secure input must not get a synthesized paste")
        }
    }

    func testWithoutAccessibilityTheTextStaysOnTheClipboard() {
        guard case .clipboardOnly = OutputPolicy.decide(secureInput: false, accessibilityTrusted: false) else {
            return XCTFail("without Accessibility a posted Cmd+V is dropped silently")
        }
    }

    // Mutation: ignore `focusMoved` in OutputPolicy.decide -> RED (the text is
    // pasted into whatever app the user switched to).
    func testNoPasteIntoAnAppTheUserSwitchedTo() {
        guard case .clipboardOnly = OutputPolicy.decide(secureInput: false, focusMoved: true, accessibilityTrusted: true) else {
            return XCTFail("a paste must go where the user dictated, not where focus went later")
        }
    }

    func testPastesOtherwise() {
        XCTAssertEqual(OutputPolicy.decide(secureInput: false, accessibilityTrusted: true), .paste)
    }
}

final class WAVTests: XCTestCase {
    func testPCM16Header() {
        let d = WAV.pcm16([0, 1, -1, 2], sampleRate: 16000)
        XCTAssertEqual(d.count, 44 + 8)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        let le32 = { (o: Int) in d[o..<o+4].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        let le16 = { (o: Int) in d[o..<o+2].withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) } }
        XCTAssertEqual(le32(24), 16000)
        XCTAssertEqual(le32(40), 8)
        XCTAssertEqual(le16(44), 0)
        XCTAssertEqual(le16(46), 32767)
        XCTAssertEqual(le16(48), -32767)
        XCTAssertEqual(le16(50), 32767, "out-of-range samples are clipped, not wrapped")
    }
}

final class TranscriptionClientTests: XCTestCase {
    func testSendsMultipartAndReturnsTrimmedText() async throws {
        var seen: URLRequest?
        let client = TranscriptionClient(model: "parakeet") { req in
            seen = req
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"text":"  привет, мир \n"}"#.utf8), resp)
        }
        let text = try await client.transcribe([Float](repeating: 0, count: 16000))
        XCTAssertEqual(text, "привет, мир")
        let req = try XCTUnwrap(seen)
        XCTAssertEqual(req.url?.path, "/v1/audio/transcriptions")
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nparakeet"))
        XCTAssertTrue(body.contains("filename=\"dictation.wav\""))
    }

    func testATimeoutIsNotReportedAsADeadDaemon() async {
        let client = TranscriptionClient { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.transcribe([0])
            XCTFail("a timeout must not read as text")
        } catch let e as TranscriptionError {
            XCTAssertEqual(e, .timedOut)
        } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorIsReported() async {
        let client = TranscriptionClient { req in
            (Data("queue full".utf8), HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.transcribe([0])
            XCTFail("a 503 must not read as text")
        } catch let e as TranscriptionError {
            XCTAssertEqual(e, .http(503, "queue full"))
        } catch { XCTFail("\(error)") }
    }
}

final class FakeRecorder: Recorder {
    var started = 0
    var stopped = 0
    var samples: [Float] = []
    var onStart: (() -> Void)?
    var startError: Error?
    var prepareError: Error?
    var onSamples: (([Float]) -> Void)?
    func prepare() throws {
        if let prepareError { throw prepareError }
    }
    func start() throws {
        started += 1
        onStart?()
        if let startError { throw startError }
    }
    func stop() -> [Float] { stopped += 1; return samples }
}

final class FakeOutput: TextOutput {
    var delivered: [String] = []
    func deliver(_ text: String) { delivered.append(text) }
}

final class DictationControllerTests: XCTestCase {
    @MainActor func run(_ c: DictationController, until state: DictationState, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.state, state, "stuck: every later key press would be ignored", file: file, line: line)
    }

    @MainActor
    func testHoldRecordsWhileHeldThenDelivers() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in "hello" }
        c.keyDown()
        XCTAssertEqual(c.state, .recording)
        c.keyDown() // key repeat while holding: ignored
        XCTAssertEqual(rec.started, 1)
        c.keyUp()
        XCTAssertEqual(c.state, .transcribing)
        await run(c, until: .idle)
        XCTAssertEqual(out.delivered, ["hello"])
    }

    // Mutation: remove the minSeconds check in DictationController.finish ->
    // RED (a key tap sends silence to the daemon and may paste a stray word).
    @MainActor
    func testAKeyTapIsDropped() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0, count: 1600) // 0.1 s
        let out = FakeOutput()
        var transcribed = false
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in transcribed = true; return "x" }
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertFalse(transcribed)
        XCTAssertEqual(out.delivered, [])
    }

    @MainActor
    func testToggleStartsAndStopsOnPresses() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let c = DictationController(recorder: rec, output: out, mode: .toggle) { _ in "toggled" }
        c.keyDown(); c.keyUp()
        XCTAssertEqual(c.state, .recording, "in toggle mode the release does not stop")
        c.keyDown()
        await run(c, until: .idle)
        XCTAssertEqual(out.delivered, ["toggled"])
    }

    @MainActor
    func testATranscriptionErrorIsReportedAndNothingIsPasted() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var errors: [String] = []
        let c = DictationController(recorder: rec, output: out) { _ in throw TranscriptionError.badResponse }
        c.onError = { errors.append($0) }
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(out.delivered, [])
        XCTAssertEqual(errors.count, 1)
    }
}

final class CancelTests: XCTestCase {
    @MainActor func run(_ c: DictationController, until state: DictationState, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.state, state, "stuck: every later key press would be ignored", file: file, line: line)
    }

    @MainActor
    func testCancelWhileRecordingSendsNothing() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        var transcribed = false
        let c = DictationController(recorder: rec, output: out, mode: .hold) { _ in transcribed = true; return "x" }
        c.keyDown()
        c.cancel()
        XCTAssertEqual(c.state, .idle)
        // Mutation: `_ = recorder.stop()` -> `break` in DictationController.cancel
        // -> RED (the microphone would stay on after Esc).
        XCTAssertEqual(rec.stopped, 1, "Esc must turn the microphone off")
        c.keyUp() // the release after Esc must not start a transcription
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(transcribed)
        XCTAssertEqual(out.delivered, [])
    }

    // Mutation: delete `guard started == generation else { return }` in
    // DictationController.finish -> RED: the late text is pasted, and the old
    // task flips the new recording to idle.
    @MainActor
    func testCancelWhileTranscribingDropsTheLateResult() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let c = DictationController(recorder: rec, output: out, mode: .toggle) { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return "late"
        }
        c.keyDown(); c.keyDown()
        XCTAssertEqual(c.state, .transcribing)
        c.cancel()
        XCTAssertEqual(c.state, .idle)
        c.keyDown() // a new recording starts before the old request returns
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(out.delivered, [])
        XCTAssertEqual(c.state, .recording, "the cancelled request must not end the new recording")
    }
}

final class LevelMeterTests: XCTestCase {
    func tone(_ hz: Double, amplitude: Float, count: Int = 1024) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 16000)) }
    }

    func testSilenceIsZero() {
        let m = LevelMeter()
        XCTAssertEqual(m.levels([Float](repeating: 0, count: 1024)), [Float](repeating: 0, count: 9))
        XCTAssertEqual(m.levels([]).count, 9)
    }

    // Mutation: in LevelMeter.levels replace `for k in lo..<min(hi, power.count)`
    // with `for k in 0..<1` (every band reads the DC bin) -> RED.
    func testTheToneLightsItsOwnBand() {
        let m = LevelMeter()
        // Bands are log-spaced 100 Hz ... 5 kHz: 300 Hz is band 2, 2.5 kHz band 7.
        for (hz, band) in [(300.0, 2), (2500.0, 7)] {
            let levels = m.levels(tone(hz, amplitude: 0.1)) // -20 dBFS: speech at a normal distance
            XCTAssertEqual(levels.firstIndex(of: levels.max()!), band, "\(hz) Hz -> \(levels)")
            XCTAssertGreaterThan(levels[band], 0.8)
            XCTAssertLessThan(levels[0], 0.3, "a far band stays low: \(levels)")
        }
    }

    func testQuietIsLowButNotNothing() {
        let m = LevelMeter()
        let whisper = m.levels(tone(1000, amplitude: 0.001))[5] // -60 dBFS
        let normal = m.levels(tone(1000, amplitude: 0.05))[5]    // -26 dBFS
        XCTAssertGreaterThan(whisper, 0)
        XCTAssertLessThan(whisper, 0.5)
        XCTAssertGreaterThan(normal, whisper)
    }
}

final class ControllerEdgeTests: XCTestCase {
    @MainActor func run(_ c: DictationController, until state: DictationState) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.state, state)
    }

    // Mutation: in DictationController.finish change `where !text.isEmpty` to
    // `where true` -> RED (an empty result would replace the clipboard with nothing).
    @MainActor
    func testAnEmptyTranscriptionDeliversNothing() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let c = DictationController(recorder: rec, output: out) { _ in "" }
        c.keyDown(); c.keyUp()
        await run(c, until: .idle)
        XCTAssertEqual(out.delivered, [])
    }

    @MainActor
    func testFinishRecordingTranscribesWhatWasRecorded() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        let out = FakeOutput()
        let c = DictationController(recorder: rec, output: out, mode: .toggle) { _ in "capped" }
        c.keyDown()
        c.finishRecording()
        await run(c, until: .idle)
        XCTAssertEqual(out.delivered, ["capped"])
    }

    @MainActor
    func testAPressWhileTranscribingIsReported() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
        var busy = 0
        let c = DictationController(recorder: rec, output: FakeOutput()) { _ in
            try await Task.sleep(nanoseconds: 100_000_000); return "x"
        }
        c.onBusy = { busy += 1 }
        c.keyDown(); c.keyUp()
        c.keyDown()
        XCTAssertEqual(busy, 1)
        XCTAssertEqual(rec.started, 1, "no second recording while the first is transcribing")
        await run(c, until: .idle)
    }
}

final class DaemonAddressTests: XCTestCase {
    func plist(_ env: [String: String]?) -> Data {
        var dict: [String: Any] = ["Label": "io.github.anatolykoptev.ox-say"]
        if let env { dict["EnvironmentVariables"] = env }
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // Mutation: make DaemonAddress.url(agentPlist:) return `fallback` right away
    // -> RED (a daemon moved to another port is never found).
    func testReadsTheInstalledAddress() {
        XCTAssertEqual(DaemonAddress.url(agentPlist: plist(["OX_SAY_ADDR": "127.0.0.1:9123"])).absoluteString, "http://127.0.0.1:9123")
    }

    func testDefaultsWithoutAPlistOrSetting() {
        XCTAssertEqual(DaemonAddress.url(agentPlist: nil), DaemonAddress.fallback)
        XCTAssertEqual(DaemonAddress.url(agentPlist: plist(nil)), DaemonAddress.fallback)
        XCTAssertEqual(DaemonAddress.url(agentPlist: Data("not a plist".utf8)), DaemonAddress.fallback)
    }

    func testListenAddressForms() {
        XCTAssertEqual(DaemonAddress.url(listenAddress: ":8094")?.absoluteString, "http://127.0.0.1:8094")
        XCTAssertEqual(DaemonAddress.url(listenAddress: "0.0.0.0:8094")?.absoluteString, "http://127.0.0.1:8094")
        XCTAssertEqual(DaemonAddress.url(listenAddress: "[::1]:8094")?.absoluteString, "http://[::1]:8094")
        XCTAssertEqual(DaemonAddress.url(listenAddress: "localhost:8094")?.absoluteString, "http://localhost:8094")
        XCTAssertNil(DaemonAddress.url(listenAddress: "8094"))
        XCTAssertNil(DaemonAddress.url(listenAddress: "host:99999"))
        XCTAssertNil(DaemonAddress.url(listenAddress: "evil.example/path:80"))
    }
}

final class ShortcutConflictTests: XCTestCase {
    let space = 49, control = 0x1000, option = 0x800, command = 0x100, shift = 0x200

    // Mutation: return false from ShortcutConflict.taken -> RED (a stock Mac's
    // ⌃Space input-source switch would silently fight the dictation key).
    func testStockInputSourceShortcutTakesControlSpace() {
        let stock = [SystemShortcut(keyCode: space, modifiers: control, enabled: true)]
        XCTAssertTrue(ShortcutConflict.taken(keyCode: space, modifiers: control, by: stock))
        XCTAssertFalse(ShortcutConflict.taken(keyCode: space, modifiers: option, by: stock))
    }

    func testDisabledOrDifferentShortcutsDoNotCount() {
        // This Mac: input sources on ⌘Space, emoji on ⌃⌘Space, ⌃⇧Space disabled.
        let here = [
            SystemShortcut(keyCode: space, modifiers: command, enabled: true),
            SystemShortcut(keyCode: space, modifiers: control | command, enabled: true),
            SystemShortcut(keyCode: space, modifiers: control | shift, enabled: false),
        ]
        XCTAssertFalse(ShortcutConflict.taken(keyCode: space, modifiers: control, by: here))
        XCTAssertFalse(ShortcutConflict.taken(keyCode: space, modifiers: control | shift, by: here))
    }

    // Mutation: drop `$0.keyCode == keyCode &&` from ShortcutConflict.taken -> RED.
    func testSameModifiersOnAnotherKeyDoNotCount() {
        let controlF = [SystemShortcut(keyCode: 3, modifiers: control, enabled: true)]
        XCTAssertFalse(ShortcutConflict.taken(keyCode: space, modifiers: control, by: controlF))
    }

    func testCapsLockBitDoesNotMatter() {
        let stock = [SystemShortcut(keyCode: space, modifiers: control | 0x400, enabled: true)]
        XCTAssertTrue(ShortcutConflict.taken(keyCode: space, modifiers: control, by: stock))
    }
}

final class ShortcutMenuTests: XCTestCase {
    let space = 49, control = 0x1000, option = 0x800
    var ctrl: ShortcutMenu.Choice { ShortcutMenu.Choice(title: "⌃Space", keyCode: space, modifiers: control) }
    var opt: ShortcutMenu.Choice { ShortcutMenu.Choice(title: "⌥Space", keyCode: space, modifiers: option) }
    /// Offered in the same preference order as the app's Shortcut.allCases.
    var offers: [ShortcutMenu.Choice] { [ctrl, opt] }
    /// A stock Mac: ⌃Space switches input sources.
    var stock: [SystemShortcut] { [SystemShortcut(keyCode: space, modifiers: control, enabled: true)] }

    // Mutation: always use `isEnabled: true` and the bare title when building
    // ShortcutMenu.Plan.items -> RED (a macOS-owned key stays clickable and
    // unmarked). This guards the rows' computation only: whether menuWillOpen
    // applies them is AppKit glue that swift test does not link.
    func testTheItemsFollowTheSystemShortcuts() {
        let taken = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: stock)
        XCTAssertEqual(taken.items[0], ShortcutMenu.Item(title: "⌃Space (a macOS shortcut)", isEnabled: false, isOn: false))
        XCTAssertEqual(taken.items[1], ShortcutMenu.Item(title: "⌥Space", isEnabled: true, isOn: true))

        // The same call after the key is freed un-greys it: the refresh path
        // asks again every menu open, so the answer must come from `system`.
        let freed = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: [])
        XCTAssertEqual(freed.items[0], ShortcutMenu.Item(title: "⌃Space", isEnabled: true, isOn: false))
    }

    // The decision: with no stored pick, a working key does not move when a
    // more preferred key frees up — a shortcut freed in System Settings was
    // usually freed for something else, and grabbing it would fight that.
    // Mutation: `key = choices.firstIndex(where: isFree)` in the no-stored
    // branch of ShortcutMenu.plan -> RED (⌃Space is silently claimed).
    func testAWorkingKeyIsNotMovedForPreference() {
        let plan = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: [])
        XCTAssertEqual(plan.key, 1, "⌥Space is registered and still free: stay on it")
        XCTAssertNil(plan.movedFrom, "no move, nothing to announce")
        XCTAssertTrue(plan.items[1].isOn)
    }

    // Mutation: drop the `movedFrom = choices.firstIndex(of:)` assignments in
    // ShortcutMenu.plan -> RED (a forced move goes back to silent).
    func testLosingTheActiveKeyMovesAndMarksIt() {
        let optTaken = [SystemShortcut(keyCode: space, modifiers: option, enabled: true)]
        let plan = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: optTaken)
        XCTAssertEqual(plan.key, 0, "⌥Space is taken: fall back to free ⌃Space")
        XCTAssertEqual(plan.movedFrom, 1, "the move off ⌥Space earns a notice")
        XCTAssertEqual(plan.items[1], ShortcutMenu.Item(title: "⌥Space (a macOS shortcut)", isEnabled: false, isOn: false))
    }

    func testAStoredPickThatMacOSTookFallsBack() {
        let plan = ShortcutMenu.plan(stored: ctrl, active: opt, choices: offers, system: stock)
        XCTAssertEqual(plan.key, 1)
        XCTAssertEqual(plan.movedFrom, 0)
    }

    func testAFreeStoredPickWinsOverTheActiveKey() {
        let plan = ShortcutMenu.plan(stored: opt, active: ctrl, choices: offers, system: [])
        XCTAssertEqual(plan.key, 1)
        XCTAssertNil(plan.movedFrom)
    }

    func testNothingFreeRegistersNothing() {
        let all = stock + [SystemShortcut(keyCode: space, modifiers: option, enabled: true)]
        let plan = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: all)
        XCTAssertNil(plan.key)
        XCTAssertTrue(plan.items.allSatisfy { !$0.isEnabled && !$0.isOn })
        XCTAssertEqual(plan.movedFrom, 1)
    }

    func testFirstLaunchTakesTheFirstFreeKeySilently() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, choices: offers, system: stock)
        XCTAssertEqual(plan.key, 1)
        XCTAssertNil(plan.movedFrom, "an initial choice is not a move")
    }

    // The app starts at login, so "a working key is not moved" has to hold
    // across a relaunch too. Mutation: drop `?? lastSession` in
    // ShortcutMenu.plan -> RED (the relaunch silently claims ⌃Space, freed
    // since the last session).
    func testARelaunchKeepsTheLastSessionsKey() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, lastSession: opt, choices: offers, system: [])
        XCTAssertEqual(plan.key, 1, "⌥Space worked last session and is still free: stay on it")
        XCTAssertNil(plan.movedFrom)
    }

    func testARelaunchAnnouncesTheMoveOffAKeyMacOSTook() {
        let plan = ShortcutMenu.plan(stored: nil, active: nil, lastSession: ctrl, choices: offers, system: stock)
        XCTAssertEqual(plan.key, 1)
        XCTAssertEqual(plan.movedFrom, 0, "⌃Space became a macOS shortcut between launches: say so")
    }

    func testTheRegisteredKeyOutranksTheLastSession() {
        let plan = ShortcutMenu.plan(stored: nil, active: ctrl, lastSession: opt, choices: offers, system: [])
        XCTAssertEqual(plan.key, 0)
        XCTAssertNil(plan.movedFrom)
    }

    // The stored pick ⌃Space was freed while dictation runs on ⌥Space, and
    // the menu opens mid-dictation. Mutation: return `(plan.items, …)`
    // unconditionally from ShortcutMenu.onOpen -> RED (⌃Space is checked
    // while ⌥Space is the key that works).
    func testABusyMenuOpenKeepsTheCheckmarkOnTheRegisteredKey() {
        let plan = ShortcutMenu.plan(stored: ctrl, active: opt, choices: offers, system: [])
        XCTAssertEqual(plan.key, 0)
        let open = ShortcutMenu.onOpen(plan, registered: 1, idle: false)
        XCTAssertFalse(open.register, "nothing re-registers mid-dictation")
        XCTAssertEqual(open.items[0], ShortcutMenu.Item(title: "⌃Space", isEnabled: true, isOn: false))
        XCTAssertEqual(open.items[1], ShortcutMenu.Item(title: "⌥Space", isEnabled: true, isOn: true))
    }

    // Mutation: drop `idle &&` in ShortcutMenu.onOpen -> RED in the busy test
    // above (a key change would re-register mid-dictation).
    func testAnIdleMenuOpenRegistersAChangedKey() {
        let plan = ShortcutMenu.plan(stored: ctrl, active: opt, choices: offers, system: [])
        let open = ShortcutMenu.onOpen(plan, registered: 1, idle: true)
        XCTAssertTrue(open.register)
        XCTAssertEqual(open.items, plan.items)
    }

    func testAnIdleMenuOpenWithTheSameKeyOnlyRefreshes() {
        let plan = ShortcutMenu.plan(stored: nil, active: opt, choices: offers, system: [])
        let open = ShortcutMenu.onOpen(plan, registered: 1, idle: true)
        XCTAssertFalse(open.register)
        XCTAssertEqual(open.items, plan.items)
    }
}

final class DictationNoticeTests: XCTestCase {
    let reason = "Recordings stop after 120 seconds."

    // Mutation: drop `kind == .outcome` from the guard in DictationNotice.merge
    // -> RED (a "Start at login" failure raised while a capped recording is
    // transcribing gets the cap prefix and spends it, so the reason never
    // reaches the dictation's own outcome).
    func testAnUnrelatedNoticeNeitherTakesNorSpendsTheReason() {
        let merged = DictationNotice.merge(endedReason: reason, into: "Start at login: denied", kind: .unrelated)
        XCTAssertEqual(merged.message, "Start at login: denied")
        XCTAssertEqual(merged.endedReason, reason, "the reason stays pending for the dictation's outcome")
    }

    // Mutation: merge never prefixes -> RED (the cap would read as an
    // unrelated failure, and the recording would end unexplained).
    func testAnOutcomeNoticeTakesTheReasonAsPrefix() {
        let merged = DictationNotice.merge(endedReason: reason, into: "the text stayed on the clipboard", kind: .outcome)
        XCTAssertEqual(merged.message, "\(reason) the text stayed on the clipboard")
        XCTAssertNil(merged.endedReason, "the reason is said once")
    }

    func testNothingPendingPassesThrough() {
        let merged = DictationNotice.merge(endedReason: nil, into: "plain", kind: .outcome)
        XCTAssertEqual(merged.message, "plain")
        XCTAssertNil(merged.endedReason)
    }
}

final class SlowTranscriptionTests: XCTestCase {
    // Mutation: return "decoding a long recording" for every state in
    // SlowTranscription.reason -> RED (a dead speech server would go unnamed).
    func testTheReasonFollowsTheSttServerState() {
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "starting"), "loading the speech model")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "stopped"), "the speech server is not running; using the slower path")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "crashed"), "the speech server is not running; using the slower path")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "off"), "the speech server is off")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: "ready"), "decoding a long recording")
        XCTAssertEqual(SlowTranscription.reason(sttServerState: nil), "the daemon did not answer")
    }

    // Mutation: read "engine" instead of "stt_server" in
    // SlowTranscription.sttServerState -> RED (the TTS engine's state would
    // label a speech-to-text stall).
    func testSttServerStateIsReadFromStatus() {
        let body = Data(#"{"engine":{"state":"ready"},"stt_server":{"state":"starting","pid":1},"voices":[]}"#.utf8)
        XCTAssertEqual(SlowTranscription.sttServerState(fromStatus: body), "starting")
        XCTAssertNil(SlowTranscription.sttServerState(fromStatus: Data("oops".utf8)))
        // An older daemon has no stt_server key at all.
        XCTAssertNil(SlowTranscription.sttServerState(fromStatus: Data(#"{"engine":{"state":"ready"},"voices":[]}"#.utf8)))
    }

    // Mutation: return 8 from SlowTranscription.explainAfter -> RED (a long
    // dictation would get the stall explanation too early).
    func testALongRecordingWaitsLongerBeforeExplaining() {
        XCTAssertEqual(SlowTranscription.explainAfter(recordingSeconds: 3), 8)
        XCTAssertEqual(SlowTranscription.explainAfter(recordingSeconds: 300), 30)
    }

    // Mutation: drop the `statusCode == 200` check in sttServerState -> RED.
    func testAnErrorStatusIsNotAState() async {
        let client = TranscriptionClient { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"stt_server":{"state":"ready"}}"#.utf8), resp)
        }
        let state = await client.sttServerState()
        XCTAssertNil(state)
    }

    @MainActor
    func testTheControllerKnowsHowLongTheRecordingWas() async {
        let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 48000)
        let c = DictationController(recorder: rec, output: FakeOutput()) { _ in "x" }
        c.keyDown(); c.keyUp()
        XCTAssertEqual(c.recordingSeconds, 3, accuracy: 0.001)
    }

    func testTheClientAsksStatus() async {
        var path = ""
        let client = TranscriptionClient { req in
            path = req.url!.path
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"stt_server":{"state":"stopped"}}"#.utf8), resp)
        }
        let state = await client.sttServerState()
        XCTAssertEqual(path, "/status")
        XCTAssertEqual(state, "stopped")
    }
}

final class DictationTimingTests: XCTestCase {
    // The log line's contract: fixed keys in a fixed order, two-decimal
    // seconds, and "none" for a session that never opened.
    func testTheLineIsKeyValueWithNoText() {
        let timing = DictationTiming(
            recordedSeconds: 19.04, releaseToTextMs: 1170,
            stats: TranscriberStats(path: .stream, sessionCreateMs: 4305, segmentsBeforeRelease: 2, tailSeconds: 10.5),
            outcome: .delivered)
        XCTAssertEqual(timing.line,
                       "outcome=delivered path=stream recorded_s=19.04 release_to_text_ms=1170 tail_s=10.50 segments_before_release=2 session_create_ms=4305")
        let oneShot = DictationTiming(recordedSeconds: 1, releaseToTextMs: 900,
                                      stats: TranscriberStats(path: .oneShot), outcome: .failed)
        XCTAssertTrue(oneShot.line.hasSuffix("session_create_ms=none"))
        XCTAssertTrue(oneShot.line.contains("path=one-shot"))
    }
}
