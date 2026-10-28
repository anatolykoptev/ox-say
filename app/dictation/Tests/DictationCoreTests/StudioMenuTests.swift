import XCTest
@testable import DictationCore

final class StudioMenuTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")
    private let available = DaemonStatus(version: "v0.1.21", studioAvailable: true)
    private func unavailable(_ reason: String? = nil, code: String? = nil) -> DaemonStatus {
        DaemonStatus(version: "v0.1.21", studioAvailable: false, studioReason: reason, studioReasonCode: code)
    }
    private func job(_ status: ProduceStatus, done: Int = 2, total: Int = 5) -> ProduceJob {
        ProduceJob(id: "j", title: "Ch 1", status: status, partsTotal: total, partsDone: done)
    }
    private func rows(_ status: DaemonStatus?, installing: Bool = false, job: ProduceJob? = nil,
                      waiting: Bool = false, folder: Bool = false, reading: Bool = false) -> [MenuRow] {
        let service = status.map { StudioMenu.ServiceState.answered($0) } ?? .unreachable
        return StudioMenu.rows(service: service, installing: installing, job: job, serviceWaiting: waiting,
                               hasOutputFolder: folder, readingDocument: reading, text: en)
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
    private let installRow = MenuRow.item(title: "Install Studio Voice (about 3 GB)…", isOn: false, isEnabled: true, action: .installStudioVoice)

    func testAMissingModelOffersOnlyTheInstall() {
        let result = rows(unavailable("The studio voice model is not downloaded yet. Run the installer with OX_SAY_WITH_VOXCPM2=1 to add it.",
                                      code: "model_missing"))
        XCTAssertEqual(result, [installRow])
    }

    func testAnOldDaemonThatSaysNothingStillOffersTheInstall() {
        XCTAssertEqual(rows(unavailable()), [installRow])
    }

    func testInstallRowIsDisabledWhileAnInstallRuns() {
        XCTAssertEqual(rows(unavailable(code: "model_missing"), installing: true),
                       [.item(title: StudioMenu.installTitle(text: en), isOn: false, isEnabled: false, action: .installStudioVoice)])
    }

    /// Mutation: StudioMenu.swift rows, `guard status.installWouldHelp` -> `guard true` -> RED.
    func testAMacThatCannotRunItIsNeverOfferedTheInstall() {
        let reason = "Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them."
        let plain = MenuRow.item(title: "Studio voices need a Mac with Apple Silicon; this computer cannot run them.",
                                 isOn: false, isEnabled: false, action: nil)
        XCTAssertEqual(rows(unavailable(reason, code: "unsupported")), [plain])
        XCTAssertEqual(rows(unavailable(reason)), [plain], "a reason without a code: no 3 GB download either")
        XCTAssertEqual(rows(unavailable(reason, code: "a_code_from_the_future")), [plain])
        XCTAssertEqual(titles(rows(unavailable(nil, code: "unsupported"))), ["This Mac can't run the studio voice."])
    }

    func testReasonLosesTheTerminalInstruction() {
        XCTAssertEqual(StudioMenu.unavailableText(reason: "The studio voice model is not downloaded yet. Run the installer with OX_SAY_WITH_VOXCPM2=1 to add it.", text: en),
                       "The studio voice model is not downloaded yet.")
        XCTAssertEqual(StudioMenu.unavailableText(reason: "Reinstall ox-say with OX_SAY_WITH_VOXCPM2=1.", text: en), "This Mac can't run the studio voice.")
        XCTAssertEqual(StudioMenu.unavailableText(reason: "", text: en), "This Mac can't run the studio voice.")
    }

    func testDaemonErrorsLoseTerminalJargon() {
        let fallback = "The ox-say service answered with an error (400)."
        XCTAssertEqual(PlainWords.clean("produce needs a saved voice: design one with voice_design or add one with voice_add", fallback: fallback), fallback)
        XCTAssertEqual(PlainWords.clean("Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them.", fallback: fallback),
                       "Studio voices need a Mac with Apple Silicon; this computer cannot run them.")
        XCTAssertEqual(PlainWords.clean("The script is empty. Reinstall with OX_SAY_WITH_VOXCPM2=1.", fallback: fallback), "The script is empty.")
        XCTAssertEqual(PlainWords.clean("", fallback: fallback), fallback)
        XCTAssertEqual(PlainWords.clean("   ", fallback: fallback), fallback, "a blank message never makes a blank alert")
        XCTAssertEqual(PlainWords.clean("\n", fallback: fallback), fallback)
    }

    func testRefusalMessagesArePlainToo() {
        let body = Data(#"{"error":{"message":"produce needs a saved voice: design one with voice_design or add one with voice_add"}}"#.utf8)
        XCTAssertEqual(StudioClient.refusal(status: 400, body: body),
                       .refused(status: 400, message: ""), "jargon-only: the app words the status sentence when it shows it")
        XCTAssertEqual(StudioClient.refusal(status: 400, body: body).message(text: en), "The ox-say service answered with an error (400).")
    }

    func testUnreachableDaemonDisablesStudio() {
        let result = rows(nil)
        XCTAssertEqual(result, [.item(title: StudioMenu.noServiceTitle(text: en), isOn: false, isEnabled: false, action: nil)])
    }

    /// Mutation: StudioMenu.swift rows, `.unreachable` case returns only the
    /// noService row (drop `jobRows(...) +`) -> RED.
    func testOneFailedStatusKeepsTheFollowedVoiceoversRows() {
        let result = rows(nil, job: job(.running))
        XCTAssertEqual(titles(result), ["“Ch 1” — 2 of 5 parts", "Stop Voiceover", StudioMenu.noServiceTitle(text: en)])
        XCTAssertTrue(result.contains(.item(title: "Stop Voiceover", isOn: false, isEnabled: true, action: .stopVoiceover)))
    }

    func testBeforeTheFirstReplyTheServiceIsNeitherUpNorNotAnswering() {
        let result = StudioMenu.rows(service: .unknown, installing: false, job: nil, serviceWaiting: false, hasOutputFolder: false, text: en)
        XCTAssertEqual(result, [.item(title: StudioMenu.checkingTitle(text: en), isOn: false, isEnabled: false, action: nil)])
        XCTAssertFalse(titles(result).contains(StudioMenu.noServiceTitle(text: en)))
    }

    func testAFollowedVoiceoverSaysItIsWaitingWhileTheServiceIsGone() {
        let result = titles(rows(available, job: job(.running), waiting: true))
        XCTAssertTrue(result.contains("“Ch 1” — waiting for the ox-say service…"))
        XCTAssertFalse(result.contains("“Ch 1” — 2 of 5 parts"))
    }

    func testAvailableStudioWithoutAJob() {
        XCTAssertEqual(titles(rows(available, folder: true)),
                       ["New Voiceover from Document…", "Open Voiceovers Folder", "---", "Create a Voice…"])
        XCTAssertTrue(rows(available).contains(.item(title: "Open Voiceovers Folder", isOn: false, isEnabled: false, action: nil)),
                      "no folder yet: the row is disabled")
    }

    func testRunningJobShowsProgressAndStop() {
        let result = rows(available, job: job(.running), folder: true)
        XCTAssertEqual(titles(result), ["New Voiceover from Document…", "“Ch 1” — 2 of 5 parts", "Stop Voiceover",
                                        "Open Voiceovers Folder", "---", "Create a Voice…"])
        XCTAssertTrue(result.contains(.item(title: "New Voiceover from Document…", isOn: false, isEnabled: false, action: .newVoiceover)),
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
        XCTAssertEqual(result, ["New Voiceover from Document…", "Open Voiceovers Folder", "---", "Create a Voice…"])
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

    func testTheNewVoiceoverRowIsDisabledWhileADocumentIsBeingRead() {
        let newRow: (Bool) -> MenuRow? = { reading in
            self.rows(self.available, reading: reading).first { row in
                if case .item(_, _, _, .newVoiceover) = row { return true }
                return false
            }
        }
        XCTAssertEqual(newRow(false), .item(title: StudioMenu.newVoiceoverTitle(text: en), isOn: false, isEnabled: true, action: .newVoiceover))
        XCTAssertEqual(newRow(true), .item(title: StudioMenu.newVoiceoverTitle(text: en), isOn: false, isEnabled: false, action: .newVoiceover))
    }
}

