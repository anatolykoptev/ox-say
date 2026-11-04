import XCTest
@testable import DictationCore

/// Task 13 (one-window plan): what Озвучка may draw per engine. The matrix is the
/// honest-controls rule: a control is drawn only if it changes the output on the
/// engine that is selected.
final class SpeakControlsTests: XCTestCase {
    private func shown(_ engine: SpeakEngine, designed: Bool = false, advanced: Bool = false,
                       copies: Bool = false) -> Set<SpeakControl> {
        SpeakControls.shown(engine: engine, voiceIsDesigned: designed, advanced: advanced, copiesRecordingStyle: copies)
    }

    /// Mutation: SpeakControls.swift, add `case cfg` to SpeakControl -> RED.
    func testTheScreenCanOnlyEverDrawTheseTwelveThings() {
        XCTAssertEqual(Set(SpeakControl.allCases.map(\.rawValue)),
            ["voice", "quality", "variant", "phrases", "mood", "loudness", "pace", "pause", "takes", "seed", "cloneMode", "steps"])
    }

    /// Mutation: SpeakControls.swift, the `case .fast:` branch returns the studio set -> RED.
    func testTheFastVoiceNeverShowsWhatItCannotDo() {
        for advanced in [false, true] {
            let s = shown(.fast, designed: true, advanced: advanced)
            for c: SpeakControl in [.phrases, .mood, .pace, .pause, .takes, .cloneMode, .steps] {
                XCTAssertFalse(s.contains(c), "\(c) on the fast voice, advanced=\(advanced)")
            }
        }
        XCTAssertEqual(shown(.fast, designed: false, advanced: true), [.voice, .quality, .variant, .loudness, .seed])
        XCTAssertEqual(shown(.fast, designed: true, advanced: false), [.voice, .quality, .variant])
    }

    /// Mutation: SpeakControls.swift, drop the `voiceIsDesigned` condition on simple studio mood -> RED.
    func testSimpleStudioShowsMoodOnlyForADesignedVoice() {
        XCTAssertTrue(shown(.studio, designed: true).contains(.mood))
        XCTAssertFalse(shown(.studio, designed: false).contains(.mood))
        XCTAssertTrue(shown(.studio, designed: false, advanced: true).contains(.mood))
    }

    func testMoodIsHiddenWhenTheRecordingsOwnDeliveryIsCopied() {
        XCTAssertFalse(shown(.studio, designed: true, advanced: true, copies: true).contains(.mood))
        XCTAssertFalse(shown(.studio, designed: true, advanced: false, copies: true).contains(.mood))
        // Only the mood goes: the rest of the advanced studio set stays.
        XCTAssertEqual(shown(.studio, advanced: true, copies: true), shown(.studio, advanced: true).subtracting([.mood]))
    }

    func testSimpleModeHasNoAdvancedKnobs() {
        let s = shown(.studio, designed: true)
        for c: SpeakControl in [.loudness, .pace, .pause, .takes, .seed, .cloneMode, .steps] { XCTAssertFalse(s.contains(c), "\(c)") }
        XCTAssertEqual(s, [.voice, .quality, .variant, .phrases, .mood])
    }

    func testAdvancedStudioShowsEverything() {
        XCTAssertEqual(shown(.studio, advanced: true), Set(SpeakControl.allCases))
    }

    func testEveryEngineAlwaysHasTheThreeBasics() {
        for engine in [SpeakEngine.fast, .studio] {
            for advanced in [false, true] {
                XCTAssertTrue(shown(engine, advanced: advanced).isSuperset(of: [.voice, .quality, .variant]))
            }
        }
    }

    // MARK: studio availability

    func testStudioAvailabilityFromStatus() {
        XCTAssertEqual(StudioAvailability.of(nil), .unknown)
        XCTAssertEqual(StudioAvailability.of(.init(version: "1", studioAvailable: true)), .available)
        XCTAssertEqual(StudioAvailability.of(.init(version: "1", studioAvailable: false, studioReason: "x",
                                                   studioReasonCode: DaemonStatus.reasonModelMissing)), .notInstalled)
        XCTAssertEqual(StudioAvailability.of(.init(version: "1", studioAvailable: false, studioReason: "Apple Silicon only",
                                                   studioReasonCode: "unsupported")), .unsupported("Apple Silicon only"))
    }

    func testAnAvailableStudioVoiceIsNeverCalledMissing() {
        XCTAssertEqual(StudioAvailability.of(.init(version: "1", studioAvailable: true,
                                                   studioReasonCode: DaemonStatus.reasonModelMissing)), .available)
    }

    func testAReasonWithoutACodeIsNotAnInstallOffer() {
        XCTAssertEqual(StudioAvailability.of(.init(version: "1", studioAvailable: false, studioReason: "Needs 24 GB.")),
                       .unsupported("Needs 24 GB."))
    }

    func testNoteOnlyWhenTheStudioVoiceCannotBeChosen() {
        XCTAssertNil(SpeakControls.studioNote(.available, text: { $0.rawValue }))
        XCTAssertNil(SpeakControls.studioNote(.unknown, text: { $0.rawValue }))
        XCTAssertEqual(SpeakControls.studioNote(.notInstalled, text: { $0.rawValue }), L10nKey.speakStudioNotInstalled.rawValue)
        XCTAssertEqual(SpeakControls.studioNote(.unsupported("Apple Silicon only"), text: { $0.rawValue }), "Apple Silicon only")
    }

    func testAnUnsupportedReasonThatIsJargonOrEmptyBecomesThePlainSentence() {
        XCTAssertEqual(SpeakControls.studioNote(.unsupported(""), text: { $0.rawValue }), L10nKey.speakCannotRun.rawValue)
        XCTAssertEqual(SpeakControls.studioNote(.unsupported("Reinstall with OX_SAY_WITH_VOXCPM2=1."), text: { $0.rawValue }),
                       L10nKey.speakCannotRun.rawValue)
    }

    /// Settings -> Add-ons does not exist until window-plan Task 27, so the sentence points nowhere: the page offers the
    /// existing studio install action beside it. Task 27 restores the pointer.
    func testTheShippedNotInstalledSentenceHasNoDeadPointer() {
        let ru = ShippedStrings.localizer("ru"), en = ShippedStrings.localizer("en")
        XCTAssertEqual(SpeakControls.studioNote(.notInstalled, text: ru), "Студийный голос не скачан.")
        XCTAssertEqual(SpeakControls.studioNote(.notInstalled, text: en), "The studio voice is not downloaded.")
    }

    /// The daemon's own English reasons (internal/config/config.go VoxCPM2Block, the exact Go output) become ru/en sentences.
    /// Mutation: SpeakText.studioReason, drop the Apple Silicon branch -> RED.
    func testTheDaemonsKnownUnsupportedReasonsAreTranslated() {
        let ru = ShippedStrings.localizer("ru"), en = ShippedStrings.localizer("en")
        let silicon = "Studio voices (VoxCPM2) need a Mac with Apple Silicon; this computer cannot run them."
        let memory = "Studio voices (VoxCPM2) need at least 24 GB of memory; this Mac has 16 GB."
        XCTAssertEqual(SpeakControls.studioNote(.unsupported(silicon), text: ru), "Студийный голос работает только на Mac с Apple Silicon.")
        XCTAssertEqual(SpeakControls.studioNote(.unsupported(silicon), text: en), "The studio voice needs a Mac with Apple Silicon.")
        XCTAssertEqual(SpeakControls.studioNote(.unsupported(memory), text: ru), "Студийному голосу нужно 24 ГБ памяти, а на этом Mac — 16 ГБ.")
        XCTAssertEqual(SpeakControls.studioNote(.unsupported(memory), text: en), "The studio voice needs 24 GB of memory; this Mac has 16 GB.")
        for note in [SpeakControls.studioNote(.unsupported(silicon), text: ru), SpeakControls.studioNote(.unsupported(memory), text: ru)] {
            XCTAssertFalse(note?.contains("VoxCPM2") ?? true, "the engine's name is not shown")
        }
    }
}
