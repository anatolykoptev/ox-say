import XCTest
@testable import DictationCore

final class CleanActionStateTests: XCTestCase {
    private func status(_ clean: CleanStatus?) -> DaemonStatus { DaemonStatus(version: "v1", studioAvailable: false, voiceClean: clean) }
    private let done = CleanDone(inputPath: "/x/in.mov", outputPath: "/x/in-clean.mov", video: true, seconds: 60)

    private func state(_ clean: CleanStatus?, working: CleanWork? = nil, done: CleanDone? = nil, error: String? = nil) -> CleanActionState {
        CleanActionState.of(status: status(clean), working: working, done: done, error: error)
    }

    /// Mutation: CleanActionState.of ignores `status` (drops the reason switch) -> RED (the first two assertions).
    func testUnavailableSaysWhyAndOffersNoButton() {
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "os_too_old")), .unavailable(reason: L10nKey.cleanReasonOSTooOld.text))
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "engine_missing")), .unavailable(reason: L10nKey.cleanReasonEngineMissing.text))
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "whatever")), .unavailable(reason: L10nKey.cleanReasonUnknown.text))
        XCTAssertEqual(state(nil), .unavailable(reason: L10nKey.cleanReasonUnknown.text), "a daemon without voice_clean")
    }

    /// The first cleanup downloads the model, so a missing model is a button with a note, not a dead end.
    func testAMissingModelStillOffersTheButton() {
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "models_missing")), .idle(firstUse: true))
        XCTAssertEqual(state(CleanStatus(available: true)), .idle(firstUse: false))
    }

    /// A running job is never hidden or replaced by a status read, whatever the status says.
    /// Mutation: CleanActionState.of checks `status` before `working` -> RED.
    func testARunningJobWinsOverTheStatus() {
        let gone = CleanStatus(available: false, reasonCode: "os_too_old")
        XCTAssertEqual(state(gone, working: CleanWork(name: "a.mov")), .working(name: "a.mov", cancelling: false))
        XCTAssertEqual(state(gone, working: CleanWork(name: "a.mov", cancelling: true)), .working(name: "a.mov", cancelling: true))
    }

    func testAFinishedJobStaysAndAFailureYieldsToAnUnavailableCleaner() {
        XCTAssertEqual(state(CleanStatus(available: true), done: done), .done(done))
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "os_too_old"), done: done), .done(done))
        XCTAssertEqual(state(CleanStatus(available: true), error: "boom"), .failed("boom"))
        XCTAssertEqual(state(CleanStatus(available: false, reasonCode: "os_too_old"), error: "boom"), .unavailable(reason: L10nKey.cleanReasonOSTooOld.text))
    }

    func testTheBarIsHiddenWhilePageHasNothingToActOnUnlessThereIsAJob() {
        XCTAssertFalse(CleanActionState.idle(firstUse: false).isShown(on: .offline("x")))
        XCTAssertFalse(CleanActionState.idle(firstUse: false).isShown(on: .loading))
        XCTAssertTrue(CleanActionState.idle(firstUse: false).isShown(on: .empty))
        XCTAssertTrue(CleanActionState.idle(firstUse: false).isShown(on: .list(stale: nil)))
        XCTAssertTrue(CleanActionState.working(name: "a", cancelling: false).isShown(on: .offline("x")))
        XCTAssertTrue(CleanActionState.failed("x").isShown(on: .loading))
    }

    func testStatusDecodesVoiceClean() throws {
        let a = try XCTUnwrap(DaemonStatus.decode(Data(#"{"version":"v1","voice_clean":{"available":false,"reason_code":"models_missing","installing":true}}"#.utf8)))
        XCTAssertEqual(a.voiceClean, CleanStatus(available: false, reasonCode: "models_missing", installing: true))
        let b = try XCTUnwrap(DaemonStatus.decode(Data(#"{"version":"v1"}"#.utf8)))
        XCTAssertNil(b.voiceClean)
        let c = try XCTUnwrap(DaemonStatus.decode(Data(#"{"voice_clean":{"available":true,"reason_code":""}}"#.utf8)))
        XCTAssertEqual(c.voiceClean, CleanStatus(available: true))
    }

    func testDoneNamesItsFileAndEachSidePlaysItsOwn() {
        XCTAssertEqual(done.name, "in-clean.mov")
        XCTAssertEqual(done.url(for: .original).path, "/x/in.mov")
        XCTAssertEqual(done.url(for: .cleaned).path, "/x/in-clean.mov")
    }
}
