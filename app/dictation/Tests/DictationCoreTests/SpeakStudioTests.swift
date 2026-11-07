import XCTest
@testable import DictationCore

final class SpeakStudioTests: XCTestCase {
    private func body(_ start: StudioStart) throws -> [String: Any] {
        let data = ProduceRequest.createBody(script: start.script, title: start.title, voice: nil, format: start.format, options: start.options)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Controller note 1 (#487): the studio voice counts and sends the trimmed script.
    func testTheStudioStartCarriesTheTrimmedScript() throws {
        let typed = "  \n\nПервый абзац.\n\n\n\nВторой.  \n "
        let start = try XCTUnwrap(SpeakStudio.start(text: typed))
        XCTAssertEqual(start.script, ScriptLimit.script(from: typed))
        XCTAssertNotEqual(start.script, typed)
        let sent = try body(start)
        XCTAssertEqual(sent["script"] as? String, start.script)
        XCTAssertNil(SpeakStudio.start(text: "  \n "), "nothing to voice")
    }

    /// Under `auto` a designed voice with a reference text resolves to ultimate and the daemon then answers 409 to any
    /// mood change (`deliveryModeGate`, internal/daemon/produce_ops.go).
    func testEveryProjectFromOzvuchkaIsCreatedWithReferenceCloning() throws {
        let start = try XCTUnwrap(SpeakStudio.start(text: "Привет."))
        let sent = try body(start)
        XCTAssertEqual(sent["clone_mode"] as? String, "reference")
        XCTAssertEqual(sent["preset"] as? String, "youtube")
        XCTAssertEqual(start.format, .long)
        XCTAssertEqual(start.title, "Привет.")
    }

    func testTheOldCreateBodyIsUnchangedWithoutOptions() throws {
        let data = ProduceRequest.createBody(script: "s", title: "", voice: nil, format: .short)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["script", "preset"])
        let all = ProduceRequest.createBody(script: "s", title: "", voice: nil, format: .short,
                                            options: VoiceoverOptions(takes: 1, cloneMode: "reference", loudness: -14, steps: 8, seed: 3, outPath: "/x"))
        let full = try XCTUnwrap(JSONSerialization.jsonObject(with: all) as? [String: Any])
        XCTAssertEqual(Set(full.keys), ["script", "preset", "takes", "clone_mode", "loudness_lufs", "inference_timesteps", "seed", "out_path"])
    }

    func testTheStudioIsUsedOnlyWhenChosenAndAvailable() {
        XCTAssertEqual(SpeakStudio.engine(chosen: .studio, studio: .available), .studio)
        XCTAssertEqual(SpeakStudio.engine(chosen: .fast, studio: .available), .fast)
        for gone in [StudioAvailability.notInstalled, .unsupported("x"), .unknown] {
            XCTAssertEqual(SpeakStudio.engine(chosen: .studio, studio: gone), .fast, "\(gone): the choice falls back, it never sends a job the Mac cannot run")
        }
    }

    func testStudioTextsAreCheckedByTheTrimmedScript() {
        let padded = String(repeating: " ", count: 50_000) + "Привет"
        XCTAssertNil(SpeakInputCheck.problem(padded, engine: .studio, text: { $0.rawValue }))
        XCTAssertNotNil(SpeakInputCheck.problem(padded, engine: .fast, text: { $0.rawValue }))
    }
}
