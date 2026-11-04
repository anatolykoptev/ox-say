import Foundation
import XCTest
@testable import DictationCore

/// «Записать свой голос»: the sheet's decisions (VoiceRecording) — when the microphone is asked, how long a take must
/// be, when it stops itself, what a meeting recording does to it, and what «Сохранить» sends. The recorder, the
/// timer and the daemon call are the app's; the pins at the bottom read their source.
final class VoiceRecordingTests: XCTestCase {
    private let en = ShippedStrings.localizer("en")

    private func ready(_ language: String = "en") -> VoiceRecording {
        var r = VoiceRecording(language: language, text: en)
        _ = r.micStatus(.authorized)
        return r
    }

    /// A take of `seconds`, stopped: the review.
    private func reviewed(_ seconds: Double) -> VoiceRecording {
        var r = ready()
        XCTAssertEqual(r.start(text: en), .startRecorder)
        r.stop(seconds: seconds)
        return r
    }

    // MARK: length

    /// Under five seconds there is too little voice to clone: «Сохранить» is off and a forced save is refused.
    /// Mutation: VoiceRecording.swift "seconds >= minimumSeconds" -> "true" -> RED.
    func testTooShortCannotBeSaved() {
        var r = reviewed(4.9)
        XCTAssertFalse(r.canSave)
        XCTAssertNil(r.save(taken: [], text: en))
        XCTAssertEqual(r.problem, en(.voiceRecordTooShort).replacingOccurrences(of: "%d", with: "5"))
        XCTAssertEqual(r.phase, .review(seconds: 4.9), "a refused save keeps the take on screen")
        var long = reviewed(5.0)
        XCTAssertTrue(long.canSave)
        XCTAssertNotNil(long.save(taken: [], text: en))
    }

    /// At twenty seconds the take ends by itself and goes to the review; just under, it keeps recording.
    /// Mutation: VoiceRecording.swift "maximumSeconds" in `tick` -> ".infinity" -> RED.
    func testStopsItselfAtTwentySeconds() {
        var r = ready()
        _ = r.start(text: en)
        XCTAssertNil(r.tick(seconds: 19.9))
        XCTAssertEqual(r.phase, .recording)
        XCTAssertEqual(r.tick(seconds: 20.0), .stopRecorder)
        XCTAssertEqual(r.phase, .review(seconds: 20.0))
        // A late tick of a take that already ended changes nothing.
        XCTAssertNil(r.tick(seconds: 20.4))
        XCTAssertEqual(r.phase, .review(seconds: 20.0))
    }

    func testTheLiveTimerFollowsTheTicks() {
        var r = ready()
        _ = r.start(text: en)
        _ = r.tick(seconds: 7.5)
        XCTAssertEqual(r.seconds, 7.5)
    }

    // MARK: microphone

    /// Denied: the sheet says so and offers System Settings; there is no Record button to press into silence.
    func testDeniedMicrophoneShowsTheSettingsLinkNotARecordButton() {
        var r = VoiceRecording(language: "en", text: en)
        XCTAssertNil(r.micStatus(.denied))
        XCTAssertEqual(r.phase, .needsMicrophone(denied: true))
        XCTAssertTrue(r.showsSettingsLink)
        XCTAssertFalse(r.showsRecordButton)
        XCTAssertNil(r.start(text: en), "a denied microphone never starts the recorder")
        XCTAssertEqual(r.phase, .needsMicrophone(denied: true))
    }

    /// Not decided yet: the first answer asks (one effect), the next reads wait for the person's answer without asking
    /// again; the answer then moves on.
    func testNotDeterminedAsksOnceAndWaits() {
        var r = VoiceRecording(language: "en", text: en)
        XCTAssertEqual(r.micStatus(.notDetermined), .askMicrophone)
        XCTAssertEqual(r.phase, .needsMicrophone(denied: false))
        XCTAssertNil(r.micStatus(.notDetermined), "the question is on screen already")
        XCTAssertFalse(r.showsRecordButton)
        XCTAssertFalse(r.showsSettingsLink)
        XCTAssertNil(r.micStatus(.authorized))
        XCTAssertEqual(r.phase, .ready)
        XCTAssertTrue(r.showsRecordButton)
    }

    /// Allowed later in System Settings: the window comes back, reads again and the Record button returns.
    func testGrantingItInSettingsReturnsTheRecordButton() {
        var r = VoiceRecording(language: "en", text: en)
        _ = r.micStatus(.denied)
        _ = r.micStatus(.authorized)
        XCTAssertEqual(r.phase, .ready)
    }

    /// A read that arrives while a take is on screen changes nothing about that take.
    func testAMicrophoneReadDuringATakeLeavesItAlone() {
        var r = ready()
        _ = r.start(text: en)
        _ = r.micStatus(.authorized)
        XCTAssertEqual(r.phase, .recording)
        r.stop(seconds: 8)
        _ = r.micStatus(.authorized)
        XCTAssertEqual(r.phase, .review(seconds: 8))
    }

    // MARK: prompts

    func testPromptsExistInBothLanguagesAndAreLongEnough() {
        for language in ["ru", "en"] {
            let prompts = VoiceRecording.prompts(language: language)
            XCTAssertEqual(prompts.count, 3, language)
            for prompt in prompts {
                // 12-18 s at reading pace is roughly 170-260 characters; the floor guards an empty or stub passage and the
                // ceiling a passage that cannot be read inside the 20 s the recording allows.
                XCTAssertGreaterThanOrEqual(prompt.count, 90, prompt)
                XCTAssertLessThanOrEqual(prompt.count, 280, prompt)
            }
            XCTAssertEqual(Set(prompts).count, 3, "three different passages")
        }
        XCTAssertNotEqual(VoiceRecording.prompts(language: "ru"), VoiceRecording.prompts(language: "en"))
        XCTAssertTrue(VoiceRecording.prompts(language: "ru")[0].range(of: "[а-яё]", options: .regularExpression) != nil)
        XCTAssertEqual(VoiceRecording.prompts(language: "de"), VoiceRecording.prompts(language: "en"), "other languages read English")
    }

    func testAnotherTextCyclesThroughThePassages() {
        var r = ready("ru")
        let first = r.prompt
        r.nextPrompt()
        XCTAssertNotEqual(r.prompt, first)
        r.nextPrompt(); r.nextPrompt()
        XCTAssertEqual(r.prompt, first, "after the last passage the first comes back")
        _ = r.start(text: en)
        let during = r.prompt
        r.nextPrompt()
        XCTAssertEqual(r.prompt, during, "the passage does not change under a take")
    }

    // MARK: takes

    func testRecordingAgainDiscardsTheLastTake() {
        var r = reviewed(9)
        XCTAssertEqual(r.phase, .review(seconds: 9))
        XCTAssertEqual(r.start(text: en), .startRecorder)
        XCTAssertEqual(r.phase, .recording)
        XCTAssertEqual(r.seconds, 0, "the previous take's length is gone")
        XCTAssertFalse(r.canSave)
        r.stop(seconds: 6)
        XCTAssertEqual(r.phase, .review(seconds: 6))
    }

    func testStartIsOnlyForTheStatesThatMayRecord() {
        var r = ready()
        _ = r.start(text: en)
        XCTAssertNil(r.start(text: en), "already recording")
        var saving = reviewed(8)
        _ = saving.save(taken: [], text: en)
        XCTAssertNil(saving.start(text: en), "the take is being sent")
        var fresh = VoiceRecording(language: "en", text: en)
        XCTAssertNil(fresh.start(text: en), "the microphone has not been read as allowed")
    }

    // MARK: meeting

    /// A meeting recording holds the microphone: the voice recording does not start, and says why.
    /// Mutation: VoiceRecording.swift the `meetingRecording` refusal in `start` deleted -> RED.
    func testAMeetingRecordingRefusesTheStart() {
        var r = ready()
        XCTAssertNil(r.start(meetingRecording: true, text: en))
        XCTAssertEqual(r.phase, .failed(en(.voiceRecordBlockedMeeting)))
        // Once the meeting ends, the person tries again.
        XCTAssertEqual(r.start(meetingRecording: false, text: en), .startRecorder)
        XCTAssertEqual(r.phase, .recording)
    }

    /// A dictation holds the microphone too: the voice recording does not start, and says why.
    /// Mutation: VoiceRecording.swift the `dictationRecording` refusal in `start` deleted -> RED.
    func testADictationRecordingRefusesTheStart() {
        var r = ready()
        XCTAssertNil(r.start(dictationRecording: true, text: en))
        XCTAssertEqual(r.phase, .failed(en(.voiceRecordBlockedDictation)))
        // Once the dictation ends, the person tries again.
        XCTAssertEqual(r.start(text: en), .startRecorder)
        XCTAssertEqual(r.phase, .recording)
    }

    /// «Записать ещё раз» refused by a meeting or a dictation: the reviewed take stays and the sentence is said under it.
    /// Mutation: VoiceRecording.swift refuseStart() review branch -> `phase = .failed(sentence)` -> RED.
    func testARefusedRerecordKeepsTheReviewedTake() {
        var meeting = reviewed(8)
        XCTAssertNil(meeting.start(meetingRecording: true, text: en))
        XCTAssertEqual(meeting.phase, .review(seconds: 8), "the take is still there")
        XCTAssertEqual(meeting.problem, en(.voiceRecordBlockedMeeting))
        XCTAssertTrue(meeting.canSave, "and it can still be saved")
        var dictation = reviewed(8)
        XCTAssertNil(dictation.start(dictationRecording: true, text: en))
        XCTAssertEqual(dictation.phase, .review(seconds: 8))
        XCTAssertEqual(dictation.problem, en(.voiceRecordBlockedDictation))
        // Once the meeting ends, «Записать ещё раз» starts a new take and the sentence goes.
        XCTAssertEqual(meeting.start(text: en), .startRecorder)
        XCTAssertNil(meeting.problem)
    }

    /// A meeting starts during a take: the take is stopped and thrown away, and the sheet says so.
    func testAMeetingStartingDuringATakeDiscardsIt() {
        var r = ready()
        _ = r.start(text: en)
        _ = r.tick(seconds: 4)
        XCTAssertEqual(r.meetingStarted(text: en), .discardTake)
        XCTAssertEqual(r.phase, .failed(en(.voiceRecordMeetingStarted)))
        XCTAssertFalse(r.canSave)

        var review = reviewed(9)
        XCTAssertEqual(review.meetingStarted(text: en), .discardTake)
        XCTAssertEqual(review.phase, .failed(en(.voiceRecordMeetingStarted)))

        var idle = ready()
        XCTAssertNil(idle.meetingStarted(text: en), "nothing to discard before a take")
        XCTAssertEqual(idle.phase, .ready)
    }

    // MARK: closing

    /// Esc during a take stops and discards it; elsewhere it just closes; while the take is being sent it cannot.
    func testEscapeStopsAndDiscardsATakeInProgress() {
        var r = ready()
        _ = r.start(text: en)
        XCTAssertTrue(r.mayClose)
        XCTAssertEqual(r.escape(), .discardTake)

        var review = reviewed(8)
        XCTAssertEqual(review.escape(), .discardTake, "a kept-in-memory take is dropped too")

        var saving = reviewed(8)
        _ = saving.save(taken: [], text: en)
        XCTAssertFalse(saving.mayClose)
        XCTAssertNil(saving.escape())
        XCTAssertEqual(saving.phase, .saving)
    }

    // MARK: saving

    /// «Сохранить» sends the slug id, the cleaned label, the passage that was read as the reference text and the
    /// `recorded` source.
    func testSaveBuildsTheDaemonRequestWithThePassageAsRefText() {
        var r = ready("ru")
        let passage = r.prompt
        _ = r.start(text: en)
        r.stop(seconds: 12)
        r.edit(label: "  Мой голос ")
        let request = r.save(taken: [], text: en)
        XCTAssertEqual(request, VoiceRecording.Request(id: "moy-golos", label: "Мой голос", refText: passage, source: "recorded"))
        XCTAssertEqual(r.phase, .saving)
        XCTAssertNil(r.save(taken: [], text: en), "one add at a time")
    }

    func testTheLabelStartsAsMyVoice() {
        XCTAssertEqual(VoiceRecording(language: "en", text: en).label, en(.voiceRecordLabelDefault))
    }

    /// The default label is the first name the library does not have: «My voice», then «My voice 2», «My voice 3»…,
    /// by the same rule «Сохранить» checks (the id it slugs to or the label itself, case-insensitively).
    /// Mutation: VoiceRecording.swift defaultLabel -> `base` -> RED.
    func testTheDefaultLabelIsTheFirstFreeName() {
        XCTAssertEqual(VoiceRecording.defaultLabel(taken: [], text: en), "My voice")
        XCTAssertEqual(VoiceRecording.defaultLabel(taken: ["my voice"], text: en), "My voice 2")
        XCTAssertEqual(VoiceRecording.defaultLabel(taken: ["my voice", "my voice 2"], text: en), "My voice 3")
        XCTAssertEqual(VoiceRecording.defaultLabel(taken: ["my-voice"], text: en), "My voice 2",
                       "the slugged id counts as taken too")
        let ru = ShippedStrings.localizer("ru")
        XCTAssertEqual(VoiceRecording(language: "ru", taken: ["мой голос"], text: ru).label, "Мой голос 2")
    }

    /// The taken-name rule is the other sheets' (VoiceName.isTaken): the id the label slugs to, or the label itself
    /// case-insensitively, names an existing voice.
    func testATakenNameIsRefusedBeforeUpload() {
        for name in ["my-voice", "My Voice", "MY VOICE"] {
            var r = reviewed(8)
            r.edit(label: name)
            XCTAssertNil(r.save(taken: ["my-voice", "my voice"], text: en), name)
            XCTAssertEqual(r.problem, en(.designProblemNameTaken), name)
            XCTAssertEqual(r.phase, .review(seconds: 8), name)
        }
        var empty = reviewed(8)
        empty.edit(label: "   ")
        XCTAssertNil(empty.save(taken: [], text: en))
        XCTAssertEqual(empty.problem, en(.voicesRenameInvalid))
    }

    /// The daemon refused: the take and the typed name stay, the sentence shows, and a retry may be sent.
    func testARefusedAddKeepsTheTake() {
        var r = reviewed(8)
        r.edit(label: "Anya")
        _ = r.save(taken: [], text: en)
        XCTAssertNil(r.refused("the clip could not be decoded"))
        XCTAssertEqual(r.phase, .review(seconds: 8))
        XCTAssertEqual(r.problem, "the clip could not be decoded")
        XCTAssertEqual(r.label, "Anya")
        XCTAssertTrue(r.canSave)
        XCTAssertNotNil(r.save(taken: [], text: en))
    }

    /// The daemon refused while the window was already closed: there is nowhere to show the sentence, so the take
    /// is thrown away instead of waiting in memory for a review nobody can see.
    /// Mutation: VoiceRecording.swift the `windowGone` arm of `refused` deleted -> RED.
    func testARefusedAddWithTheWindowGoneDiscardsTheTake() {
        var r = reviewed(8)
        _ = r.save(taken: [], text: en)
        XCTAssertEqual(r.refused("the clip could not be decoded", windowGone: true), .discardTake)
        var kept = reviewed(8)
        _ = kept.save(taken: [], text: en)
        XCTAssertNil(kept.refused("no", windowGone: false))
        XCTAssertEqual(kept.phase, .review(seconds: 8), "the window is up: the take stays for another try")
    }

    func testARecorderFailureIsShownAndRecordingCanStartAgain() {
        var r = ready()
        _ = r.start(text: en)
        r.recorderFailed("No microphone input is available.")
        XCTAssertEqual(r.phase, .failed("No microphone input is available."))
        XCTAssertEqual(r.start(text: en), .startRecorder)
    }

    // MARK: the meter

    /// Reduce Motion: no bars move; the number of seconds is shown instead.
    func testTheMeterIsStaticUnderReduceMotion() {
        XCTAssertEqual(VoiceRecording.meterBars(levels: [0.2, 0.9, 0.5], reduceMotion: true), Array(repeating: 0, count: 9))
        XCTAssertEqual(VoiceRecording.meterBars(levels: [0.2, 0.9, 0.5], reduceMotion: false).count, 9)
        XCTAssertEqual(VoiceRecording.meterBars(levels: [], reduceMotion: false), Array(repeating: 0, count: 9))
    }

    // MARK: the work a relaunch must wait for

    /// Which phases are work a relaunch must wait for: a take in progress, kept or being sent. VoiceSource reads
    /// this through `recordingVoice`. Mutation: VoiceRecording.swift `isWork` -> `false` -> RED.
    func testThePhasesThatAreWork() {
        var r = VoiceRecording(language: "en", text: en)
        XCTAssertFalse(r.isWork, "ready")
        _ = r.micStatus(.denied)
        XCTAssertFalse(r.isWork, "needsMicrophone")
        r = ready()
        _ = r.start(text: en)
        XCTAssertTrue(r.isWork, "a take in progress")
        r.stop(seconds: 8)
        XCTAssertTrue(r.isWork, "a kept take")
        _ = r.save(taken: [], text: en)
        XCTAssertTrue(r.isWork, "a take being sent")
        var failed = ready()
        _ = failed.start(meetingRecording: true, text: en)
        XCTAssertFalse(failed.isWork, "a refused start holds nothing")
    }

    /// A voice recording is work: a relaunch or a daemon restart waits for it.
    /// Mutation: VersionHandshake.AppWork.idle, drop `|| recordingVoice` -> RED.
    func testARecordingVoiceIsWork() {
        let busy = VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                            recordingMeeting: false, recordingVoice: true)
        XCTAssertFalse(busy.idle)
        XCTAssertTrue(VersionHandshake.AppWork(dictating: false, speaking: false, designing: false, followingVoiceover: false,
                                               recordingMeeting: false).idle)
    }

    // MARK: pins on the app's source (the shim compiles DictationCore only)

    private func body(_ text: String, of signature: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "\(signature) not found")
        let rest = text[start.lowerBound...]
        var end = rest.endIndex
        if let next = rest.dropFirst(signature.count).range(of: "\n    private func |\n    func |\n    // MARK", options: .regularExpression) {
            end = next.lowerBound
        }
        return String(rest[..<end])
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The version handshake reads the live recording state. PIN (source text).
    /// Mutation: AppDelegate.swift `recordingVoice:` input in appWork() -> `false` -> RED.
    func testRecordingVoiceHoldsTheHandshake() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        let start = try XCTUnwrap(app.range(of: "private func appWork() -> VersionHandshake.AppWork {"))
        let end = try XCTUnwrap(app.range(of: "\n    }\n", range: start.upperBound..<app.endIndex))
        let body = String(app[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("recordingVoice:"), body)
        XCTAssertFalse(body.contains("recordingVoice: false"), "the input must be the live state")
        XCTAssertTrue(body.contains("recordingVoice: mainWindow.source?.recordingVoice"), body)
    }

    /// Dictation records at 16 kHz, byte-identical to before: the app builds its recorder with no argument and the
    /// recorder's default is 16000. PIN (source text).
    /// Mutation: MicRecorder.swift "sampleRate: Int = 16000" -> "24000" -> RED.
    func testDictationRecorderStaysAt16k() throws {
        let app = try source("OxSayDictation/AppDelegate.swift")
        XCTAssertTrue(app.contains("private let recorder = MicRecorder()"))
        let mic = try source("OxSayDictation/MicRecorder.swift")
        XCTAssertTrue(mic.contains("sampleRate: Int = 16000"))
        XCTAssertFalse(mic.contains("sampleRate: Int = 24000"))
    }

    /// The voice recorder is the 24 kHz one, and a meeting recording is read live at the press. PIN (source text).
    func testTheVoiceRecorderIsWiredAt24kAndBehindTheMeetingGate() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("MicRecorder(sampleRate: VoiceRecording.sampleRate)"))
        XCTAssertTrue(voice.contains("meetingRecording: recordingRunning()"))
        XCTAssertTrue(voice.contains("change { $0.meetingStarted() }"), "a meeting starting during a take must reach the reducer")
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("voiceSource.meetingStarted()"))
        XCTAssertTrue(window.contains("voiceSource.quietRecording()"))
    }

    /// The person's voice must not stay on disk: the temp folder (0700) is removed once the add call returns, whether
    /// it succeeded or failed. PIN (source text) on the `defer`.
    /// Mutation: VoiceSource.swift the `removeItem` of the temp dir deleted -> RED.
    func testRecordedClipIsRemovedAfterTheAddCall() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("defer { try? FileManager.default.removeItem(at: dir) }"))
        XCTAssertTrue(voice.contains("ox-say-voice-"))
        XCTAssertTrue(voice.contains("posixPermissions: 0o700"))
        XCTAssertTrue(voice.contains("source: \"recorded\""))
        // The defer is declared before the add call, so it runs on every way out.
        let defers = try XCTUnwrap(voice.range(of: "defer { try? FileManager.default.removeItem(at: dir) }"))
        let add = try XCTUnwrap(voice.range(of: "source: \"recorded\""))
        XCTAssertLessThan(defers.lowerBound, add.lowerBound)
    }

    /// The microphone is asked here, on the first «Записать», never by a read or at launch. PIN (source text).
    func testTheMicrophoneIsAskedOnlyThroughTheReducersEffect() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertEqual(voice.components(separatedBy: "AVCaptureDevice.requestAccess").count - 1, 1)
        let ask = try XCTUnwrap(voice.range(of: "case .askMicrophone"))
        let request = try XCTUnwrap(voice.range(of: "AVCaptureDevice.requestAccess"))
        XCTAssertLessThan(ask.lowerBound, request.lowerBound)
    }

    /// The take's end releases a deferred relaunch: `record`'s didSet is the one place the true→false transition is
    /// noticed (close, save success or failure, discard, meeting started), and it calls the same work-ended hook the
    /// design path does. PIN (source text).
    /// Mutation: VoiceSource.swift the `workEnded()` call deleted -> RED.
    func testAFinishedTakeReleasesTheDeferredRelaunch() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("if oldValue?.isWork == true, record?.isWork != true { workEnded() }"),
                      "the work flag's true→false edge fires the release once, on every write to record")
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("workEnded: { host.workEnded() }"), "the hook is the host's workEnded")
        let app = try source("OxSayDictation/AppDelegate.swift")
        let host = try body(app, of: "func windowHost() -> MainWindowHost {")
        XCTAssertTrue(host.contains("workEnded: { [unowned self] in self.handshakeWorkEnded() }"),
                      "and that is the handshake's release, the one VoiceDesigner uses")
    }

    /// A kept take never stays in memory once nothing is shown: `record`'s didSet drops the samples whenever the
    /// phase stops being work — `.failed` included, the «Записать ещё раз» refusal path. PIN (source text).
    /// Mutation: VoiceSource.swift the `takeSamples = []` in `record`'s didSet deleted -> RED.
    func testAGoneTakeKeepsNoSamples() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("if record?.isWork != true { takeSamples = [] }"))
    }

    /// Esc or a close while the take is being sent is refused by the reducer's `mayClose`, not by the window's
    /// willingness to close. PIN (source text) that cannot match elsewhere — the guard names `record` itself.
    /// Mutation: VoiceSource.swift `guard var r = record, r.mayClose` -> `guard var r = record` -> RED.
    func testASavingTakeKeepsTheSheetOpen() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("guard var r = record, r.mayClose"))
    }

    /// «Записать» reads the dictation state live and hands it to the reducer; the host answers with the
    /// controller's. PIN (source text) at the call site.
    /// Mutation: VoiceSource.swift `dictationRecording: dictationRecording()` -> `dictationRecording: false` -> RED.
    func testTheDictationGateReachesTheReducer() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("dictationRecording: dictationRecording()"))
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("dictationRecording: { host.dictationRecording() }"))
        let app = try source("OxSayDictation/AppDelegate.swift")
        let host = try body(app, of: "func windowHost() -> MainWindowHost {")
        XCTAssertTrue(host.contains("dictationRecording: { [unowned self] in self.controller.state == .recording }"))
    }

    /// A refused save with the window closed discards the take: the glue asks `windowGone` and carries out the
    /// reducer's `.discardTake`. PIN (source text).
    /// Mutation: VoiceSource.swift `windowGone: windowGone()` -> `windowGone: false` -> RED.
    func testARefusedSaveAsksWhetherTheWindowIsGone() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("windowGone: windowGone()"))
        XCTAssertTrue(voice.contains("perform(.discardTake)\n                    record = nil"),
                      "the refused-and-closed take does not come back on reopen")
        let window = try source("OxSayDictation/MainWindowSource.swift")
        XCTAssertTrue(window.contains("windowGone:"), "the gone check is wired")
    }

    /// The sheet opens with the first free label, not the constant: the reducer gets the library's names.
    /// PIN (source text).
    /// Mutation: VoiceSource.swift `taken: takenNames()` dropped -> RED.
    func testTheSheetOpensWithAFreeLabel() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("VoiceRecording(language: L10nBundle.locale.identifier, taken: takenNames())"))
    }

    // MARK: the take is heard

    /// The player is stopped only when nobody claims it: a take that is playing stays, a preview the session no longer
    /// names goes, a silent player has nothing to stop.
    /// Mutation: VoicePlayback.swift `&& !takePlaying` dropped -> RED on the first line.
    func testAPlayingTakeIsNotStoppedBySync() {
        XCTAssertFalse(VoicePlayback.shouldStop(previewID: nil, takePlaying: true, active: true), "the take plays on")
        XCTAssertTrue(VoicePlayback.shouldStop(previewID: nil, takePlaying: false, active: true), "a preview that is gone stops")
        XCTAssertFalse(VoicePlayback.shouldStop(previewID: nil, takePlaying: false, active: false), "nothing sounds")
        XCTAssertFalse(VoicePlayback.shouldStop(previewID: "ben", takePlaying: false, active: true), "the session names it")
    }

    /// `sync` asks the function, with the live take state; the old test on the session alone would stop every take.
    /// PIN (source text).
    /// Mutation: VoiceSource.swift sync() back to `if session.playingID == nil, player.isActivelyPlaying { player.stop() }` -> RED.
    func testSyncAsksWhetherTheTakeIsPlaying() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        let sync = try body(voice, of: "private func sync(playing: String? = nil) {")
        XCTAssertTrue(sync.contains("VoicePlayback.shouldStop(previewID: session.playingID, takePlaying: recordPlaying, active: player.isActivelyPlaying)"))
        XCTAssertFalse(sync.contains("if session.playingID == nil, player.isActivelyPlaying"))
    }

    /// Whatever stops the take's player clears `recordPlaying`, so the sheet does not keep Stop for a take that ended:
    /// a library preview, a designer preview, and the stop of the previews.
    /// PIN (source text).
    /// Mutation: VoiceSource.swift `recordPlaying = false` removed from preview(_:) -> RED.
    func testAPreviewThatStopsTheTakeClearsItsFlag() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        for signature in ["func preview(_ id: String) {", "func stopPreview() {"] {
            let part = try body(voice, of: signature)
            XCTAssertTrue(part.contains("player.stop()\n        recordPlaying = false"), "\(signature) clears recordPlaying")
        }
        XCTAssertTrue(voice.contains("designer.willPlay = { [weak self] in\n            self?.player.stop()\n            self?.recordPlaying = false"))
    }

    /// The version handshake's getter: a voice recording holds the relaunch exactly while the sheet has work.
    /// PIN (source text).
    /// Mutation: VoiceSource.swift `record?.isWork ?? false` -> `false` -> RED.
    func testRecordingVoiceReadsTheSheetsWork() throws {
        let voice = try source("OxSayDictation/VoiceSource.swift")
        XCTAssertTrue(voice.contains("var recordingVoice: Bool { record?.isWork ?? false }"))
    }
}
