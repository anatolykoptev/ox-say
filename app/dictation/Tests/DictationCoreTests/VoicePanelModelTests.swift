import XCTest
@testable import DictationCore

/// Task 17 (one-window plan): the Advanced voice panel's decisions. A control is drawn only if it changes the sound on the
/// engine that is selected (plan constraint 3); a value reaches the daemon only while Advanced is on.
final class VoicePanelModelTests: XCTestCase {
    private func chunk(_ n: Int, pace: Double = 0, pause: Double = 0, style: String? = nil) -> ProduceChunkDetail {
        ProduceChunkDetail(index: n, paragraph: n, text: "t\(n)", style: style, pauseAfter: pause, pace: pace, status: .ok)
    }

    // MARK: ranges

    /// Mutation: VoicePanelModel.swift, `max(0.85, min(1.15` -> unclamped -> RED.
    func testPaceIsClampedToTheMeasuredBandAndNeutralIsOmitted() {
        XCTAssertEqual(VoicePanelModel.paceValue(1.0), nil)
        XCTAssertEqual(VoicePanelModel.paceValue(1.30), 1.15)
        XCTAssertEqual(VoicePanelModel.paceValue(0.5), 0.85)
        XCTAssertEqual(VoicePanelModel.paceValue(1.1), 1.1)
    }

    func testQualityIsEightOrTenStepsNeverSixOrMore() {
        XCTAssertEqual(VoicePanelModel.steps(.draft), 8)
        XCTAssertEqual(VoicePanelModel.steps(.final), 10)
    }

    func testLoudnessTargetsAreTheMeasuredOnes() {
        XCTAssertEqual(LoudnessTarget.reels.lufs, -14)
        XCTAssertEqual(LoudnessTarget.youtube.lufs, -16)
        XCTAssertEqual(LoudnessTarget.underMusic.lufs, -18)
        XCTAssertEqual(LoudnessTarget.broadcast.lufs, -23)
        XCTAssertEqual(LoudnessTarget.custom(-50).lufs, -40, "clamped to the daemon range")
        XCTAssertEqual(LoudnessTarget.custom(0).lufs, -5)
        XCTAssertEqual(LoudnessTarget.custom(.nan).lufs, -16, "NaN is refused by the daemon: it falls back to the YouTube level")
    }

    func testAStoredLevelComesBackAsItsNamedTargetOrCustom() {
        XCTAssertEqual(LoudnessTarget.of(lufs: -18), .underMusic)
        XCTAssertEqual(LoudnessTarget.of(lufs: -17), .custom(-17))
        XCTAssertEqual(LoudnessTarget.of(lufs: -90), .custom(-40))
    }

    /// The daemon takes 0 (clears) or 0.05...10; the panel offers 0...3 on the 0.05 grid. A value between 0 and 0.05 would be a 400.
    /// Mutation: VoicePanelModel.swift, `pauseValue` snap -> `return seconds` -> RED.
    func testPauseSnapsToTheDaemonGridAndNeverLandsBetweenZeroAndTheMinimum() {
        XCTAssertEqual(VoicePanelModel.pauseValue(0.01), 0)
        XCTAssertEqual(VoicePanelModel.pauseValue(0.02), 0)
        XCTAssertEqual(VoicePanelModel.pauseValue(0.03), 0.05)
        XCTAssertEqual(VoicePanelModel.pauseValue(0.15), 0.15)
        XCTAssertEqual(VoicePanelModel.pauseValue(5), 3)
        XCTAssertEqual(VoicePanelModel.pauseValue(-1), 0)
    }

    func testSeedAndTakesStayInTheDaemonsRanges() {
        XCTAssertEqual(VoicePanelModel.seed(-5), 0)
        XCTAssertEqual(VoicePanelModel.seed(5_000_000_000), 4_294_967_295)
        XCTAssertEqual(VoicePanelModel.seed(77), 77)
        XCTAssertEqual(VoicePanelModel.takes(0), 1)
        XCTAssertEqual(VoicePanelModel.takes(9), 3)
        XCTAssertEqual(VoicePanelModel.takes(2), 2)
    }

    // MARK: rows

    func testThePanelDrawsExactlyTheRowsTheEngineSupports() {
        let fast = VoicePanelModel.rows(controls: SpeakControls.shown(engine: .fast, voiceIsDesigned: false, advanced: true), engine: .fast).map(\.id)
        XCTAssertEqual(fast, ["voice", "loudness", "seed"])
        let studio = VoicePanelModel.rows(controls: SpeakControls.shown(engine: .studio, voiceIsDesigned: true, advanced: true), engine: .studio).map(\.id)
        XCTAssertEqual(studio, ["voice", "mood", "pace", "pause", "loudness", "quality", "cloneMode", "seed", "takes"])
        XCTAssertFalse(studio.contains("cfg")); XCTAssertFalse(studio.contains("pitch")); XCTAssertFalse(studio.contains("emotionStrength"))
    }

    /// The fast voice has no phrases, mood, pace, pause, steps, clone mode or takes: handed the studio set it still draws three rows.
    /// Mutation: VoicePanelModel.swift, drop the `engine == .studio` filter on the studio-only rows -> RED.
    func testTheFastVoiceNeverGetsAStudioRowEvenWhenHandedItsControls() {
        let everything = Set(SpeakControl.allCases)
        XCTAssertEqual(VoicePanelModel.rows(controls: everything, engine: .fast).map(\.id), ["voice", "loudness", "seed"])
    }

    func testTheMoodRowIsGoneWhenTheRecordingsDeliveryIsCopied() {
        let controls = SpeakControls.shown(engine: .studio, voiceIsDesigned: false, advanced: true, copiesRecordingStyle: true)
        XCTAssertEqual(VoicePanelModel.rows(controls: controls, engine: .studio).map(\.id),
                       ["voice", "pace", "pause", "loudness", "quality", "cloneMode", "seed", "takes"])
    }

    /// A finished studio project is on the right: the panel speaks for the studio voice whatever «Качество» says.
    /// Mutation: VoicePanelModel.swift, `projectSelected ? .studio : chosen` -> `chosen` -> RED.
    func testASelectedProjectIsAlwaysTheStudioVoice() {
        XCTAssertEqual(VoicePanelModel.engine(chosen: .fast, projectSelected: true), .studio)
        XCTAssertEqual(VoicePanelModel.engine(chosen: .fast, projectSelected: false), .fast)
        XCTAssertEqual(VoicePanelModel.engine(chosen: .studio, projectSelected: false), .studio)
    }

    // MARK: delivery entries

    /// `validateDelivery` answers 400 to an entry with no style, pause or pace, and a nil field means "leave as it is": going
    /// back to neutral must send an explicit 0, or the stored 1.10 stays while the slider says 1.00.
    /// Mutation: VoicePanelModel.swift, `paceValue(x) ?? 0` -> `paceValue(x)` for the reset -> RED.
    func testGoingBackToNeutralSendsAnExplicitZero() {
        let entries = VoicePanelModel.deliveryEntries(chunks: [chunk(0, pace: 1.1)], scope: .phrase(0), change: .pace(1.0))
        XCTAssertEqual(entries, [DeliveryEntry(n: 0, pace: 0)])
        let pause = VoicePanelModel.deliveryEntries(chunks: [chunk(0, pause: 0.5)], scope: .phrase(0), change: .pause(0))
        XCTAssertEqual(pause, [DeliveryEntry(n: 0, pauseAfter: 0)])
    }

    /// Nothing changed is nothing sent: an empty entry is a 400, and a stored 1.0 is the same as neutral.
    func testAnUnchangedPhraseSendsNothing() {
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .pace(1.0)), [])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0, pace: 1.0)], scope: .phrase(0), change: .pace(1.0)), [])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0, pace: 1.1)], scope: .phrase(0), change: .pace(1.1)), [])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0, pause: 0.5)], scope: .phrase(0), change: .pause(0.5)), [])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .mood(nil)), [])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0, style: "спокойно")], scope: .phrase(0), change: .mood(.calm)), [])
    }

    func testAPaceIsClampedAndAPauseSnappedBeforeTheyAreSent() {
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .pace(2.0)), [DeliveryEntry(n: 0, pace: 1.15)])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .pause(0.01)), [], "0.01 snaps to 0: nothing changed")
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .pause(0.03)), [DeliveryEntry(n: 0, pauseAfter: 0.05)])
    }

    /// Mutation: VoicePanelModel.swift, the `.phrase(let n)` filter -> all chunks -> RED.
    func testOnePhraseTouchesOnlyItsChunkAndAllTextEveryChangedOne() {
        let chunks = [chunk(0), chunk(1, pace: 1.1), chunk(2)]
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: chunks, scope: .phrase(2), change: .pace(1.1)), [DeliveryEntry(n: 2, pace: 1.1)])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: chunks, scope: .all, change: .pace(1.1)),
                       [DeliveryEntry(n: 0, pace: 1.1), DeliveryEntry(n: 2, pace: 1.1)], "chunk 1 already has it")
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: chunks, scope: .phrase(7), change: .pace(1.1)), [], "no such phrase")
    }

    func testAMoodGoesAsItsWordAndClearingSendsAnEmptyStyle() {
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0)], scope: .phrase(0), change: .mood(.excited)),
                       [DeliveryEntry(n: 0, style: "восторженно")])
        XCTAssertEqual(VoicePanelModel.deliveryEntries(chunks: [chunk(0, style: "тепло")], scope: .all, change: .mood(nil)),
                       [DeliveryEntry(n: 0, style: "")])
    }

    func testTheScopeIsTheChosenPhraseOrTheFirstOrNone() {
        let chunks = [chunk(3), chunk(5)]
        XCTAssertEqual(VoicePanelModel.scope(allText: true, phrase: 5, chunks: chunks), .all)
        XCTAssertEqual(VoicePanelModel.scope(allText: false, phrase: 5, chunks: chunks), .phrase(5))
        XCTAssertEqual(VoicePanelModel.scope(allText: false, phrase: nil, chunks: chunks), .phrase(3))
        XCTAssertEqual(VoicePanelModel.scope(allText: false, phrase: 9, chunks: chunks), .phrase(3), "a phrase that is gone")
        XCTAssertNil(VoicePanelModel.scope(allText: true, phrase: nil, chunks: []))
    }

    // MARK: what reaches the daemon

    private var loud = VoicePanelSettings(loudness: .underMusic, quality: .draft, copiesRecording: true, seed: 42, takes: 2)

    /// Advanced off: a control that is not drawn must not change the sound (plan constraint 3). The reel preset stays as it is.
    /// Mutation: VoicePanelModel.swift, delete the `guard advanced` in `options` -> RED.
    func testAdvancedOffNeverLeaksAPanelValue() {
        let reel = NewReelPreset.options()
        XCTAssertEqual(VoicePanelModel.options(base: reel, panel: loud, advanced: false), reel)
        let plain = VoiceoverOptions(cloneMode: "reference")
        XCTAssertEqual(VoicePanelModel.options(base: plain, panel: loud, advanced: false), plain)
        let knobs = VoicePanelModel.speechKnobs(panel: loud, advanced: false)
        XCTAssertNil(knobs.seed); XCTAssertNil(knobs.loudness)
    }

    func testAdvancedOnMergesThePanelOverTheBase() {
        let merged = VoicePanelModel.options(base: VoiceoverOptions(cloneMode: "reference"), panel: loud, advanced: true)
        XCTAssertEqual(merged, VoiceoverOptions(takes: 2, cloneMode: "ultimate", loudness: -18, steps: 8, seed: 42))
        // An untouched panel leaves the base's own values (the reel's one take and reference cloning).
        let untouched = VoicePanelModel.options(base: NewReelPreset.options(), panel: VoicePanelSettings(), advanced: true)
        XCTAssertEqual(untouched, NewReelPreset.options())
        XCTAssertEqual(untouched.takes, 1); XCTAssertEqual(untouched.cloneMode, "reference")
        // A takes count chosen in the panel wins over the reel's.
        XCTAssertEqual(VoicePanelModel.options(base: NewReelPreset.options(), panel: VoicePanelSettings(takes: 3), advanced: true).takes, 3)
        let knobs = VoicePanelModel.speechKnobs(panel: loud, advanced: true)
        XCTAssertEqual(knobs.seed, 42); XCTAssertEqual(knobs.loudness, -18)
    }

    /// Mutation: VoicePanelModel.swift, `cloneMode(copiesRecording:)` returns "ultimate" for false -> RED.
    func testTheRecordingsDeliveryIsCopiedOnlyOnRequest() {
        XCTAssertEqual(VoicePanelModel.cloneMode(copiesRecording: true), "ultimate")
        XCTAssertEqual(VoicePanelModel.cloneMode(copiesRecording: false), "reference")
    }

    func testAnOutOfRangeStoredValueIsClampedOnTheWayOut() {
        let wild = VoicePanelSettings(loudness: .custom(-99), seed: 9_999_999_999, takes: 8)
        let merged = VoicePanelModel.options(base: VoiceoverOptions(), panel: wild, advanced: true)
        XCTAssertEqual(merged.loudness, -40); XCTAssertEqual(merged.seed, 4_294_967_295); XCTAssertEqual(merged.takes, 3)
    }

    // MARK: when it applies

    /// Mutation: VoicePanelModel.swift, `loudnessAppliesNow` also true for `.running` -> RED.
    func testLoudnessAppliesAtOnceOnlyToAFinishedProject() {
        XCTAssertTrue(VoicePanelModel.loudnessAppliesNow(status: .done))
        XCTAssertTrue(VoicePanelModel.loudnessAppliesNow(status: .review))
        for status: ProduceStatus? in [.running, .failed, .cancelled, .interrupted, .pausedOnBattery, nil] {
            XCTAssertFalse(VoicePanelModel.loudnessAppliesNow(status: status), "\(String(describing: status))")
        }
    }

    func testEachCaptionSaysWhenTheRowTakesEffect() {
        XCTAssertEqual(VoicePanelModel.timing(of: "loudness", engine: .studio, finishedProject: true), .now)
        XCTAssertEqual(VoicePanelModel.timing(of: "loudness", engine: .studio, finishedProject: false), .nextVoicing)
        XCTAssertEqual(VoicePanelModel.timing(of: "loudness", engine: .fast, finishedProject: false), .nextVoicing, "a fast clip is never re-levelled")
        for row in ["quality", "cloneMode", "takes", "seed"] {
            XCTAssertEqual(VoicePanelModel.timing(of: row, engine: .studio, finishedProject: true), .nextVoicing, row)
        }
        XCTAssertEqual(VoicePanelModel.timing(of: "pace", engine: .studio, finishedProject: true), .now)
        XCTAssertEqual(VoicePanelModel.timing(of: "pause", engine: .studio, finishedProject: false), .needsProject)
        XCTAssertEqual(VoicePanelModel.timing(of: "mood", engine: .studio, finishedProject: false), .needsProject)
    }

    // MARK: storing

    func testTheSettingsSurviveARelaunchAndAnAbsentKeyIsTheDefault() {
        let d = UserDefaults(suiteName: "VoicePanel.\(UUID())")!
        XCTAssertEqual(VoicePanelSettings.load(from: d), VoicePanelSettings())
        loud.save(to: d)
        XCTAssertEqual(VoicePanelSettings.load(from: d), loud)
        VoicePanelSettings(loudness: .custom(-15.5)).save(to: d)
        XCTAssertEqual(VoicePanelSettings.load(from: d), VoicePanelSettings(loudness: .custom(-15.5)),
                       "a cleared choice must not leave the old one behind")
    }

    func testAStoredNonsenseValueLoadsAsNothing() {
        let d = UserDefaults(suiteName: "VoicePanel.\(UUID())")!
        d.set("loud", forKey: "speak.panel.quality"); d.set(-4, forKey: "speak.panel.seed"); d.set(0, forKey: "speak.panel.takes")
        XCTAssertEqual(VoicePanelSettings.load(from: d), VoicePanelSettings(seed: 0, takes: 1))
    }
}

extension VoicePanelModelTests {
    /// Every caption names what really happens: pace and pause re-assemble without a render, a mood renders the phrase again,
    /// a level is heard at once on a finished project, and the rest wait for the next voicing.
    /// Mutation: VoicePanelModel.swift, `("mood", _)` caption -> the pace one -> RED.
    func testEachCaptionIsTheOneForWhatTheRowReallyDoes() {
        func key(_ row: String, _ timing: PanelTiming, all: Bool = false, copies: Bool = false) -> L10nKey? {
            VoicePanelModel.captionKey(row: row, timing: timing, allText: all, copiesRecording: copies)
        }
        XCTAssertEqual(key("loudness", .now), .speakPanelLoudnessNow)
        XCTAssertEqual(key("loudness", .nextVoicing), .speakPanelLoudnessNext)
        XCTAssertEqual(key("pace", .now), .speakPanelNowPhrase)
        XCTAssertEqual(key("pause", .now, all: true), .speakPanelNowAll)
        XCTAssertEqual(key("mood", .now), .speakPanelMoodNow)
        XCTAssertEqual(key("mood", .now, all: true), .speakPanelMoodNowAll)
        XCTAssertEqual(key("quality", .nextVoicing), .speakPanelQualityHint)
        XCTAssertEqual(key("cloneMode", .nextVoicing), .speakPanelStyleHint)
        XCTAssertEqual(key("cloneMode", .nextVoicing, copies: true), .speakPanelStyleHintOn)
        XCTAssertEqual(key("seed", .nextVoicing), .speakPanelSeedHint)
        XCTAssertEqual(key("takes", .nextVoicing), .speakPanelTakesHint)
        XCTAssertNil(key("pace", .needsProject))
        XCTAssertNil(key("voice", .nextVoicing))
    }
}

extension VoicePanelModelTests {
    /// 198 sidebar + 180 list + 340 text + 260 panel and two dividers is 980: more than the 801 floor, which is why the window grows.
    /// (The app's panel is 300 wide at least, which makes it 1020; the numbers here are the function's own arithmetic.)
    /// Mutation: VoicePanelModel.swift, drop the `(panelOpen ? divider + panel : 0)` term -> RED.
    func testTheOpenPanelNeedsMoreThanTheWindowFloor() {
        let closed = PanelWindow.neededWidth(sidebar: 198, list: 180, detail: 340, panel: 260, divider: 1, panelOpen: false)
        let open = PanelWindow.neededWidth(sidebar: 198, list: 180, detail: 340, panel: 260, divider: 1, panelOpen: true)
        XCTAssertEqual(closed, 719)
        XCTAssertEqual(open, 980)
        XCTAssertGreaterThan(open, MainWindowSpec.minimumWidth)
    }

    /// Mutation: VoicePanelModel.swift, `growth` without the `room` limit -> RED.
    func testTheWindowGrowsByTheShortfallAndNoMoreThanTheScreenAllows() {
        XCTAssertEqual(PanelWindow.growth(needed: 980, current: 801, room: 1000), 179)
        XCTAssertEqual(PanelWindow.growth(needed: 980, current: 801, room: 100), 100)
        XCTAssertEqual(PanelWindow.growth(needed: 980, current: 1200, room: 500), 0, "already wide enough")
        XCTAssertEqual(PanelWindow.growth(needed: 980, current: 801, room: -5), 0)
    }

    func testTheWindowCannotBeDraggedUnderWhatTheOpenPanelNeeds() {
        XCTAssertEqual(PanelWindow.minimumWidth(floor: 801, needed: 980, panelOpen: true), 980)
        XCTAssertEqual(PanelWindow.minimumWidth(floor: 801, needed: 980, panelOpen: false), 801)
        XCTAssertEqual(PanelWindow.minimumWidth(floor: 801, needed: 700, panelOpen: true), 801)
    }

    func testClosingTheSidePanelGivesBackOnlyWhatOpeningAddedAndNeverGoesUnderTheFloor() {
        XCTAssertEqual(PanelWindow.shrink(grewBy: 179, current: 980, floor: 801), 179)
        XCTAssertEqual(PanelWindow.shrink(grewBy: 179, current: 850, floor: 801), 49, "the person had made it narrower meanwhile")
        XCTAssertEqual(PanelWindow.shrink(grewBy: 0, current: 980, floor: 801), 0)
    }
}
