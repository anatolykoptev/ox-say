import XCTest
@testable import DictationCore

final class StudioMenuTests: XCTestCase {
    private let available = DaemonStatus(version: "v0.1.21", studioAvailable: true)
    private func unavailable(_ reason: String? = nil) -> DaemonStatus {
        DaemonStatus(version: "v0.1.21", studioAvailable: false, studioReason: reason)
    }
    private func job(_ status: ProduceStatus, done: Int = 2, total: Int = 5) -> ProduceJob {
        ProduceJob(id: "j", title: "Ch 1", status: status, partsTotal: total, partsDone: done)
    }
    private func rows(_ status: DaemonStatus?, attempted: Bool = false, installing: Bool = false,
                      job: ProduceJob? = nil, folder: Bool = false) -> [MenuRow] {
        StudioMenu.rows(status: status, installAttempted: attempted, installing: installing, job: job, hasOutputFolder: folder)
    }
    private func titles(_ rows: [MenuRow]) -> [String] {
        rows.map { row in
            switch row {
            case .header(let title): return "# \(title)"
            case .item(let title, _, _, _): return title
            case .separator: return "---"
            }
        }
    }

    func testUnavailableStudioOffersOnlyTheInstall() {
        let result = rows(unavailable("The studio voice model is not downloaded yet. Run the installer with OX_SAY_WITH_VOXCPM2=1 to add it."))
        XCTAssertEqual(result, [.item(title: "Install Studio Voice (about 3 GB)…", isOn: false, isEnabled: true, action: .installStudioVoice)])
    }

    func testInstallRowIsDisabledWhileAnInstallRuns() {
        XCTAssertEqual(rows(unavailable(), installing: true),
                       [.item(title: StudioMenu.installTitle, isOn: false, isEnabled: false, action: .installStudioVoice)])
    }

    func testAfterAnInstallThatChangedNothingTheDaemonsReasonShows() {
        let result = rows(unavailable("Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them."), attempted: true)
        XCTAssertEqual(result, [.item(title: "Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them.",
                                      isOn: false, isEnabled: false, action: nil)])
        XCTAssertEqual(titles(rows(unavailable(nil), attempted: true)), ["This Mac can't run the studio voice."])
    }

    func testReasonLosesTheTerminalInstruction() {
        XCTAssertEqual(StudioMenu.unavailableText(reason: "The studio voice model is not downloaded yet. Run the installer with OX_SAY_WITH_VOXCPM2=1 to add it."),
                       "The studio voice model is not downloaded yet.")
        XCTAssertEqual(StudioMenu.unavailableText(reason: "Reinstall ox-say with OX_SAY_WITH_VOXCPM2=1."), "This Mac can't run the studio voice.")
        XCTAssertEqual(StudioMenu.unavailableText(reason: ""), "This Mac can't run the studio voice.")
    }

    func testUnreachableDaemonDisablesStudio() {
        let result = rows(nil)
        XCTAssertEqual(result, [.item(title: StudioMenu.noServiceTitle, isOn: false, isEnabled: false, action: nil)])
    }

    func testAvailableStudioWithoutAJob() {
        XCTAssertEqual(titles(rows(available, folder: true)),
                       ["New Voiceover from Text File…", "Open Voiceovers Folder", "---", "Create a Voice…"])
        XCTAssertTrue(rows(available).contains(.item(title: "Open Voiceovers Folder", isOn: false, isEnabled: false, action: nil)),
                      "no folder yet: the row is disabled")
    }

    func testRunningJobShowsProgressAndStop() {
        let result = rows(available, job: job(.running), folder: true)
        XCTAssertEqual(titles(result), ["New Voiceover from Text File…", "“Ch 1” — 2 of 5 parts", "Stop Voiceover",
                                        "Open Voiceovers Folder", "---", "Create a Voice…"])
        XCTAssertTrue(result.contains(.item(title: "New Voiceover from Text File…", isOn: false, isEnabled: false, action: .newVoiceover)),
                      "the daemon runs one voiceover at a time")
        XCTAssertTrue(result.contains(.item(title: "“Ch 1” — 2 of 5 parts", isOn: false, isEnabled: false, action: nil)))
        XCTAssertTrue(result.contains(.item(title: "Stop Voiceover", isOn: false, isEnabled: true, action: .stopVoiceover)))
    }

    func testBatteryPauseOffersToContinue() {
        let result = rows(available, job: job(.pausedOnBattery))
        XCTAssertTrue(titles(result).contains("“Ch 1” — paused — on battery power"))
        XCTAssertTrue(result.contains(.item(title: "Continue on Battery Power", isOn: false, isEnabled: true, action: .continueOnBattery)))
        XCTAssertFalse(titles(rows(available, job: job(.running))).contains("Continue on Battery Power"))
    }

    func testAFinishedJobShowsNoProgressRow() {
        let result = titles(rows(available, job: job(.done)))
        XCTAssertEqual(result, ["New Voiceover from Text File…", "Open Voiceovers Folder", "---", "Create a Voice…"])
    }

    func testVoicePopupPreselectsTheRussianPick() {
        let choices = StudioMenu.voiceChoices(voices: ["en-sam", "ru-anna"], russianPick: "ru-anna")
        XCTAssertEqual(choices.names, [nil, "en-sam", "ru-anna"])
        XCTAssertEqual(choices.selected, 2)
        XCTAssertEqual(StudioMenu.voiceChoices(voices: ["ru-anna"], russianPick: "default").selected, 0)
        XCTAssertEqual(StudioMenu.voiceChoices(voices: ["ru-anna"], russianPick: nil).selected, 0)
        XCTAssertEqual(StudioMenu.voiceChoices(voices: ["ru-anna"], russianPick: "gone").selected, 0)
    }

    func testDefaultTitleIsTheFileNameWithoutItsExtension() {
        XCTAssertEqual(StudioMenu.defaultTitle(fileName: "Chapter one.md"), "Chapter one")
        XCTAssertEqual(StudioMenu.defaultTitle(fileName: "notes.final.txt"), "notes.final")
    }
}
