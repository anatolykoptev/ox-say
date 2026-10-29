import XCTest
@testable import DictationCore

/// #211 (option b): while an update installs, a new dictation or read-aloud does not start — the installer restarts
/// the daemon in that window and would lose the text. One already running is not touched.
final class InstallWindowTests: XCTestCase {
    private static func appSource() -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private static func body(_ signature: String, in source: String) -> String {
        guard let start = source.range(of: signature),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else { return "" }
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// Mutation: UpdateGate.allowsNewDaemonWork, `!installing` -> `true` -> RED.
    func testNewDaemonWorkIsRefusedOnlyWhileAnInstallRuns() {
        XCTAssertTrue(UpdateGate.allowsNewDaemonWork(installing: false))
        XCTAssertFalse(UpdateGate.allowsNewDaemonWork(installing: true))
    }

    /// Mutation: DictationController.keyDown, delete the `guard startAllowed()` line -> RED (the recorder starts).
    @MainActor
    func testARefusedPressStartsNothingAndSaysSo() {
        let rec = FakeRecorder()
        let c = DictationController(recorder: rec, output: FakeOutput(), mode: .hold) { _ in "x" }
        var refused = 0
        c.startAllowed = { false }
        c.onStartRefused = { refused += 1 }
        c.keyDown()
        c.keyUp()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(rec.started, 0, "the microphone must not start while the daemon restarts")
        XCTAssertEqual(refused, 1)
    }

    /// The gate is a start gate: a dictation already recording when the install begins is finished by its own key
    /// (hold: release; toggle: second press) and delivered.
    /// Mutation: DictationController.keyDown, move the gate above the `switch` (so it also guards the stop) -> RED.
    @MainActor
    func testARecordingThatBeganBeforeTheInstallStillFinishesAndDelivers() async {
        for mode in [HotkeyMode.hold, .toggle] {
            let rec = FakeRecorder(); rec.samples = [Float](repeating: 0.1, count: 16000)
            let out = FakeOutput()
            let c = DictationController(recorder: rec, output: out, mode: mode) { _ in "hello" }
            c.keyDown()
            XCTAssertEqual(c.state, .recording)
            c.startAllowed = { false } // the install begins now
            if mode == .hold { c.keyUp() } else { c.keyDown() }
            XCTAssertEqual(c.state, .transcribing, "\(mode): the running dictation must end normally")
            let deadline = Date().addingTimeInterval(2)
            while c.state != .idle && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(out.delivered, ["hello"], "\(mode)")
        }
    }

    /// Mutation: AppDelegate, delete the `controller.startAllowed = ...` line -> RED.
    func testTheControllerIsAskedAboutTheInstall() {
        let app = Self.appSource()
        XCTAssertTrue(app.contains("controller.startAllowed = { [weak self] in UpdateGate.allowsNewDaemonWork(installing: self?.updateInstalling ?? false) }"),
                      "the dictation key is not gated by the install")
        XCTAssertTrue(app.contains("controller.onStartRefused = { [weak self] in self?.notice(L10nKey.noticeUpdatingDictation.text) }"),
                      "a refused press is silent")
    }

    /// Speak Selection and the Services entry both need the daemon: both refuse, before any text is captured.
    /// Mutation: AppDelegate.speakSelection or .speak, delete the `refuseSpeechWhileUpdating()` guard -> RED.
    func testBothSpeakEntriesRefuseDuringTheInstall() {
        let app = Self.appSource()
        let selection = Self.body("private func speakSelection() {", in: app)
        guard let gate = selection.range(of: "guard !refuseSpeechWhileUpdating() else { return }"),
              let capture = selection.range(of: "capture.capture()") else {
            return XCTFail("speakSelection lost its install gate or the capture")
        }
        XCTAssertLessThan(gate.lowerBound, capture.lowerBound, "the text is captured before the install is checked")
        XCTAssertTrue(Self.body("private func speak(_ text: String) {", in: app)
            .contains("guard !refuseSpeechWhileUpdating() else { return }"), "the Services entry is not gated")
        let helper = Self.body("private func refuseSpeechWhileUpdating() -> Bool {", in: app)
        XCTAssertTrue(helper.contains("UpdateGate.allowsNewDaemonWork(installing: updateInstalling)"))
        XCTAssertTrue(helper.contains("notice(L10nKey.noticeUpdatingSpeak.text)"))
    }

    /// Mutation: en or ru "notice.updating.dictation" reworded -> RED.
    func testTheNoticesAreShippedInBothLanguages() {
        let en = ShippedStrings.table("en"), ru = ShippedStrings.table("ru")
        XCTAssertEqual(en["notice.updating.dictation"], "ox-say is updating — dictation is back in a minute.")
        XCTAssertEqual(ru["notice.updating.dictation"], "ox-say обновляется — диктовка вернётся через минуту.")
        XCTAssertEqual(en["notice.updating.speak"], "ox-say is updating — reading aloud is back in a minute.")
        XCTAssertEqual(ru["notice.updating.speak"], "ox-say обновляется — чтение вслух вернётся через минуту.")
    }
}
