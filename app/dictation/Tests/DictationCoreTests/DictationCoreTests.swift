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
    func restore(_ snapshot: PasteboardSnapshot) { items = snapshot.items; changeCount += 1 }
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
    var samples: [Float] = []
    func start() throws { started += 1 }
    func stop() -> [Float] { samples }
}

final class FakeOutput: TextOutput {
    var delivered: [String] = []
    func deliver(_ text: String) { delivered.append(text) }
}

final class DictationControllerTests: XCTestCase {
    func run(_ c: DictationController, until state: DictationState) async {
        let deadline = Date().addingTimeInterval(2)
        while c.state != state && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
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
