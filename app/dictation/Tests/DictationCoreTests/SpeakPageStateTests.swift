import XCTest
@testable import DictationCore

final class SpeakPageStateTests: XCTestCase {
    func testOfflineWinsOverEverything() {
        for phase: SpeakPhase in [.idle, .generating, .ready, .failed("boom")] {
            XCTAssertEqual(SpeakPageState.of(reach: .unreachable("x"), problem: "p", phase: phase), .offline("x"), "\(phase)")
        }
    }

    func testAReachableOrUnknownDaemonIsNotOffline() {
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: nil, phase: .idle), .editing(problem: nil))
        XCTAssertEqual(SpeakPageState.of(reach: .unknown, problem: nil, phase: .idle), .editing(problem: nil))
    }

    func testTheProblemShowsWhileEditing() {
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: "too long", phase: .idle), .editing(problem: "too long"))
    }

    func testThePhasesMapToTheirStates() {
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: nil, phase: .generating), .generating(progress: nil))
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: nil, phase: .ready), .ready)
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: nil, phase: .failed("no")), .failed("no"))
    }

    func testAnEditedProblemDoesNotHideAFailureOrAWorkingJob() {
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: "p", phase: .generating), .generating(progress: nil))
        XCTAssertEqual(SpeakPageState.of(reach: .reachable, problem: "p", phase: .failed("no")), .failed("no"))
    }
}

final class SpeakInputCheckTests: XCTestCase {
    private let key: (L10nKey) -> String = { $0.rawValue }

    /// Mutation: SpeakInputCheck.problem, swap the studio cap for SpeechClient.maxInputChars -> RED.
    func testAnOverlongTextIsAProblemBeforeTheRequest() {
        let long = String(repeating: "а", count: SpeechClient.maxInputChars + 1)
        XCTAssertNotNil(SpeakInputCheck.problem(long, engine: .fast, text: key))
        XCTAssertNil(SpeakInputCheck.problem(long, engine: .studio, text: key), "the studio cap is 40000")
    }

    func testTheCapsAreInclusive() {
        XCTAssertNil(SpeakInputCheck.problem(String(repeating: "а", count: SpeechClient.maxInputChars), engine: .fast, text: key))
        XCTAssertNotNil(SpeakInputCheck.problem(String(repeating: "а", count: SpeechClient.maxInputChars + 1), engine: .fast, text: key))
        XCTAssertNil(SpeakInputCheck.problem(String(repeating: "а", count: ProduceRequest.scriptLimit), engine: .studio, text: key))
        XCTAssertNotNil(SpeakInputCheck.problem(String(repeating: "а", count: ProduceRequest.scriptLimit + 1), engine: .studio, text: key))
    }

    /// The daemon counts runes (Unicode scalars), not Characters: a letter plus a combining mark is two.
    func testLengthIsCountedInScalarsLikeTheDaemon() {
        let decomposed = String(repeating: "e\u{301}", count: SpeechClient.maxInputChars / 2 + 1)   // 2501 Characters, 5002 scalars
        XCTAssertLessThan(decomposed.count, SpeechClient.maxInputChars)
        XCTAssertNotNil(SpeakInputCheck.problem(decomposed, engine: .fast, text: key))
    }

    func testTheProblemNamesTheCapOfTheEngine() {
        let t = ShippedStrings.localizer("en")
        let fast = SpeakInputCheck.problem(String(repeating: "a", count: 5001), engine: .fast, text: t) ?? ""
        let studio = SpeakInputCheck.problem(String(repeating: "a", count: 40001), engine: .studio, text: t) ?? ""
        XCTAssertTrue(fast.contains("5000"), fast)
        XCTAssertTrue(studio.contains("40000"), studio)
    }

    func testAnEmptyTextCannotBeSpoken() {
        for engine in [SpeakEngine.fast, .studio] {
            XCTAssertEqual(SpeakInputCheck.problem("  \n", engine: engine, text: key), L10nKey.speakProblemEmpty.rawValue)
            XCTAssertEqual(SpeakInputCheck.problem("", engine: engine, text: key), L10nKey.speakProblemEmpty.rawValue)
        }
        XCTAssertNil(SpeakInputCheck.problem("Привет.", engine: .fast, text: key))
    }

    /// The studio send trims (ScriptLimit.script), so padding does not count against its cap.
    func testStudioCountsTheTrimmedScriptItSends() {
        let padded = "\n\n" + String(repeating: "а", count: ProduceRequest.scriptLimit) + "\n\n"
        XCTAssertNil(SpeakInputCheck.problem(padded, engine: .studio, text: key))
    }

    /// The studio cap is the daemon's: pinned against internal/daemon/produce.go.
    func testTheStudioCapIsTheDaemonsCap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let go = try String(contentsOf: root.appendingPathComponent("internal/daemon/produce.go"), encoding: .utf8)
        let m = try XCTUnwrap(go.range(of: #"maxProduceChars\s*=\s*\d+"#, options: .regularExpression), "maxProduceChars not found")
        XCTAssertEqual(Int(go[m].split(separator: " ").last ?? ""), ProduceRequest.scriptLimit)
    }
}
