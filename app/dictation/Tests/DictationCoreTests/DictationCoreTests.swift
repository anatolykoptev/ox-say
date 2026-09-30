import XCTest
@testable import DictationCore

/// A pasteboard that behaves like NSPasteboard: every write bumps changeCount.
final class FakePasteboard: DictationPasteboard {
    var items: [[String: Data]]
    private(set) var changeCount = 0
    init(text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]] }
    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(items: items) }
    @discardableResult func writeText(_ text: String) -> Int {
        items = [["public.utf8-plain-text": Data(text.utf8)]]
        changeCount += 1
        return changeCount
    }
    /// Like SystemPasteboard.restore: the markers go on every item put back.
    func restore(_ snapshot: PasteboardSnapshot) {
        items = snapshot.items.map { item in
            var item = item
            for marker in PasteboardMarker.restored { item[marker] = Data() }
            return item
        }
        changeCount += 1
    }
    /// The user (or another app) copies something.
    func userCopies(_ text: String) { writeText(text) }
    var text: String { String(decoding: items.first?["public.utf8-plain-text"] ?? Data(), as: UTF8.self) }
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
        board.items[0][PasteboardMarker.concealed] = Data()
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
    func start() throws { started += 1 }
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

    func testCapsLockBitDoesNotMatter() {
        let stock = [SystemShortcut(keyCode: space, modifiers: control | 0x400, enabled: true)]
        XCTAssertTrue(ShortcutConflict.taken(keyCode: space, modifiers: control, by: stock))
    }
}
