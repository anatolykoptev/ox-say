import Foundation
import XCTest
@testable import DictationCore

/// A fake output device behind the duck: one device with a level, settable
/// flag and mute; reassign `device` for a replug (new AudioObjectID), set
/// `gone` for an unplug. Writes are recorded and applied like the server.
final class FakeSystemVolume: SystemVolume {
    var device: (id: UInt32, uid: String?)? = (id: 76, uid: "fake-output")
    var gone = false
    var settable = true
    var muted = false
    var level: Float = 0.8
    /// Writes the server refused, consumed one per `setVolume`.
    var refusedWrites = 0
    /// When set, `volume` reports this — a write the server took but the
    /// read-back does not reflect.
    var reportedLevel: Float?
    /// When set, `setVolume` waits on it like a call that answers slowly.
    var gate: DispatchSemaphore?
    /// When set, a write is not visible to `volume` until `asyncLagReads`
    /// reads have passed — an output that applies volume asynchronously
    /// (Bluetooth, ramping USB DACs), where reads right after a write
    /// still return the previous level.
    var asyncLag = false
    var asyncLagReads = 1
    private var lagLeft = 0
    private var pendingWrite: Float?
    /// When set, a write lands snapped to this grid — an output whose volume
    /// comes in steps (the volume keys' 1/16) never holds the exact level
    /// the duck computed.
    var quantum: Float?
    /// Writes at this index and later are refused — a fade stopped midway.
    var refuseWritesFrom: Int?
    private(set) var writes: [Float] = []

    func defaultDevice() -> (id: UInt32, uid: String?)? { gone ? nil : device }
    func isSettable(_: UInt32) -> Bool { settable }
    func volume(_ id: UInt32) -> Float? {
        guard !gone, let device, device.id == id else { return nil }
        if pendingWrite != nil, lagLeft > 0 {
            lagLeft -= 1
            return reportedLevel ?? level
        }
        if let pendingWrite {
            level = pendingWrite
            self.pendingWrite = nil
        }
        return reportedLevel ?? level
    }
    func isMuted(_: UInt32) -> Bool { muted }
    func setVolume(_: UInt32, _ newLevel: Float) -> Bool {
        _ = gate?.wait(timeout: .now() + 1)
        writes.append(newLevel)
        if let refuseWritesFrom, writes.count > refuseWritesFrom { return false }
        if refusedWrites > 0 { refusedWrites -= 1; return false }
        let applied = quantum.map { ($0 * (newLevel / $0).rounded()) } ?? newLevel
        if asyncLag { pendingWrite = applied; lagLeft = asyncLagReads } else { level = applied }
        return true
    }
    /// Reads until a staged write has landed — the lagged reads a real
    /// settle window stands in for.
    @discardableResult
    func settleReads(_ max: Int = 8) -> Float? {
        var last: Float?
        for _ in 0..<max {
            last = volume(device?.id ?? 0)
            if pendingWrite == nil { break }
        }
        return last
    }
    func device(forUID uid: String) -> UInt32? {
        guard !gone, let device, device.uid == uid else { return nil }
        return device.id
    }
}

/// A private defaults suite that removes itself.
private func freshDefaults(_ label: String = "ox-say-sound") -> (UserDefaults, String) {
    let suite = "\(label)-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

final class VolumeDuckCoordinatorTests: XCTestCase {
    private func rig(level: Float = 0.8, logError: @escaping (String) -> Void = { _ in })
        -> (FakeSystemVolume, VolumeDuckCoordinator) {
        let fake = FakeSystemVolume()
        fake.level = level
        return (fake, VolumeDuckCoordinator(volume: fake, stepDelay: 0, logError: logError))
    }

    private let quiet = 0.8 * VolumeDuckCoordinator.duckFraction

    // F1 — journey 2: the key goes down, the output fades to a fraction of its
    // level; the key goes up, it comes back to exactly the level it had.
    // Mutation: in VolumeDuckCoordinator.restore fade `to: 1.0` (or skip the
    // restore) -> the level does not come back (RED).
    func testDuckThenRestoreToTheExactPriorLevel() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001,
                       "the output must be faint background, not silence")
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the exact pre-duck level must come back")
    }

    func testTheFadeTakesAFewStepsNotAJump() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        XCTAssertGreaterThan(fake.writes.count, 1, "a ramp, so the drop does not startle")
        XCTAssertEqual(fake.writes.last ?? 0, quiet, accuracy: 0.001)
    }

    func testMutedOrSilentOutputIsNotTouched() {
        for silent in [Float(0), -1] {
            let (fake, duck) = rig(level: silent == 0 ? 0 : 0.5)
            fake.muted = silent < 0
            duck.begin(generation: 1)
            duck.end(generation: 1)
            XCTAssertEqual(fake.writes, [], "muted/zero output: nothing to lower")
        }
    }

    // A device without a software volume (some HDMI/USB DACs): do nothing and
    // say so once per launch, not once per dictation.
    func testAnUnsettableOutputIsNotTouchedAndLoggedOnce() {
        var lines: [String] = []
        let fake = FakeSystemVolume()
        fake.settable = false
        let duck = VolumeDuckCoordinator(volume: fake, stepDelay: 0, log: { lines.append($0) })
        for generation in 1...2 { duck.begin(generation: generation); duck.end(generation: generation) }
        XCTAssertEqual(fake.writes, [])
        XCTAssertEqual(lines.count, 1, "one notice per launch")
    }

    func testNoDefaultDeviceDoesNothing() {
        let (fake, duck) = rig()
        fake.gone = true
        duck.begin(generation: 1)
        duck.end(generation: 1)
        XCTAssertEqual(fake.writes, [])
    }

    // Restore wins: the user moved the volume themselves while the duck
    // stood, and the pre-duck level still comes back — a level held for a
    // few seconds of dictation losing to the restore is the smaller harm
    // next to an output left quiet forever.
    // Mutation: in VolumeDuckCoordinator.restore return early when the
    // read-back differs from the ducked level -> the user's level is never
    // faded over (RED).
    func testAUserChangeDuringDictationIsStillRestored() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        fake.level = 0.5 // the user's own pick
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001,
                       "restore wins: the pre-duck level comes back over the user's pick")
    }

    // The reviewer's reproduction: an output that applies volume
    // asynchronously AND snaps to a step grid — pre 0.65 -> computed 0.0975
    // -> the device holds 0.125 while a read right after still answers
    // 0.65. No comparison of levels can tell that duck from a user change,
    // so restore simply wins.
    // Mutation: same early return as above -> the output stays at 0.125
    // (RED).
    func testAnAsyncQuantizingDeviceRestoresThePriorLevel() {
        let (fake, duck) = rig(level: 0.65)
        fake.quantum = 1.0 / 16
        fake.asyncLag = true
        duck.begin(generation: 1)
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.65, accuracy: VolumeDuckCoordinator.confirmTolerance,
                       "the pre-duck level comes back — the grid can only get this close")
    }

    // An output that keeps answering the old level through the whole
    // confirm window: the restore is retried once and reported at error
    // level, it stays owed — and the writes still land once the device
    // catches up. Never a loop.
    func testAThreeReadLagDeviceReportsAnUnconfirmedRestoreOnce() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        fake.asyncLag = true
        fake.asyncLagReads = 3
        duck.begin(generation: 1)
        fake.settleReads() // the duck's writes land; the device sits quiet
        let writesBeforeEnd = fake.writes.count
        duck.end(generation: 1)
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertEqual(fake.writes.count, writesBeforeEnd + 6,
                       "one fade plus one retry write — never a loop")
        fake.settleReads()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001,
                       "the writes the device lagged on still landed")
    }

    // The restore is confirmed by reading the level back; an unconfirmed write
    // is retried once, then reported at error level — never silently dropped.
    func testARefusedRestoreWriteIsRetriedOnce() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        duck.begin(generation: 1)
        fake.refusedWrites = 1
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the retry lands it")
        XCTAssertEqual(errors, [], "a recovered restore is not an error")
    }

    func testAStillUnconfirmedRestoreIsAnErrorWithoutContent() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        duck.begin(generation: 1)
        fake.reportedLevel = fake.level // the server takes the writes, the level never moves
        duck.end(generation: 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("unconfirmed") ?? false, "\(errors)")
    }

    // G3 — a pre-duck level so small that the still-ducked level sits inside
    // the confirm tolerance of it (0.06 -> ducked 0.009, off by 0.051 <
    // 0.0725): reading "close enough" proves nothing there, so a restore the
    // server REFUSED is retried and reported, not confirmed by the read.
    // Mutation: in VolumeDuckCoordinator.restore drop the write-accepted
    // conditions (`fade(...)` result and `volume.setVolume(...)` result) so
    // the read alone confirms -> RED.
    func testATinyLevelRefusedRestoreIsNotConfirmed() {
        var errors: [String] = []
        let (fake, duck) = rig(level: 0.06) { errors.append($0) }
        duck.begin(generation: 1)
        fake.refusedWrites = 2 // the fade's first step and the retry, both refused
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.06 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001,
                       "the restore never landed")
        XCTAssertEqual(errors.count, 1, "a refused restore must be reported, not confirmed: \(errors)")
        XCTAssertEqual(fake.writes.count, 5 + 1 + 1, "the duck fade, the refused fade step, the retry")
    }

    // The device the dictation ducked is restored even when it is no longer
    // the default — and is found by its UID when a replug gave it a new id.
    func testARepluggedDeviceIsFoundByUID() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        fake.device = (id: 90, uid: "fake-output") // unplugged and back as a new id
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
    }

    // A device that is gone at the end keeps its restore owed: when it is the
    // default again and still as quiet as the duck left it, the next
    // dictation gives back the ORIGINAL level.
    func testAGoneDeviceKeepsItsRestoreOwedInProcess() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        let writes = fake.writes.count
        fake.gone = true
        duck.end(generation: 1)
        XCTAssertEqual(fake.writes.count, writes, "nothing to write to a gone device")
        fake.gone = false
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the level it was owed comes back")
    }

    // Generations own their ducks: a stray end does not restore another
    // generation's duck, and a second begin does not re-duck an active one.
    func testOnlyTheOwningGenerationEndsTheDuck() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        duck.end(generation: 9)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001,
                       "another generation's end leaves the duck standing")
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
    }

    // F7 — an output whose volume comes in 1/16 steps never holds the
    // computed target (0.6875 * 0.15 = 0.103 lands on 0.125 — off by more
    // than any tight tolerance). Restore wins: the level the user had
    // comes back regardless of what the device made of the duck's writes.
    // Mutation: in restore return early when the read-back differs from
    // the computed ducked level -> the output stays at 0.125 (RED).
    func testAQuantizingDeviceRestoresTheExactPriorLevel() {
        let (fake, duck) = rig(level: 0.6875)
        fake.quantum = 1.0 / 16
        duck.begin(generation: 1)
        XCTAssertEqual(fake.level, 0.125, accuracy: 0.0001,
                       "the device snapped the target to its own step")
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.6875, accuracy: 0.0001,
                       "the level the user had comes back")
    }

    // A fade that dies midway leaves the level between pre-duck and
    // target; the restore runs from wherever the fade stopped.
    func testAPartiallyFadedDuckStillRestores() {
        let (fake, duck) = rig()
        fake.refuseWritesFrom = 2 // the third step on never lands
        duck.begin(generation: 1)
        XCTAssertEqual(fake.level, 0.528, accuracy: 0.0001,
                       "stopped between the level and the target")
        fake.refuseWritesFrom = nil
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001,
                       "the restore still gives back the level the user had")
    }

    // F8 — an unconfirmed restore stays owed and the output still quiet; the
    // next dictation must not take that quiet level as the user's own — what
    // is owed is the earlier pre-duck. Mutation: in owedPreDuck return
    // `level` unconditionally (ignore the owed entry) -> RED.
    func testANextDictationAfterAnUnconfirmedRestoreRestoresTheOriginalLevel() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        duck.begin(generation: 1)
        fake.refusedWrites = 2 // the restore tries a fade step + one retry, both refused
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001, "still quiet: the restore never landed")
        XCTAssertEqual(errors.count, 1)
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001,
                       "the ORIGINAL level comes back, not the quiet one")
    }

    // G1 — an owed restore is reused only while the output is still as quiet
    // as our duck left it. The user raised it since (0.12 -> 0.5): that level
    // is theirs, and the next dictation gives back 0.5, never the stale 0.8.
    // Mutation: in owedPreDuck drop the `level <= entry.ducked +
    // Self.confirmTolerance` guard -> the restore fades UP to 0.8 (RED).
    func testAStaleOwedRestoreIsNotReusedOnceTheUserMovedTheVolume() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        fake.refusedWrites = 2
        duck.end(generation: 1)
        fake.level = 0.5 // the user took over
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.5, accuracy: 0.0001,
                       "the stale owed level must not lift the output above what the user set")
    }

    // G2 — an owed restore belongs to its device: a dictation on another
    // output (AirPods gone, speakers now default) neither loses it nor
    // applies it there, and when the first output is the default again and
    // still quiet it gets its original level.
    // Mutation: in restore's confirmed branch replace `owed[uid] = nil` with
    // `owed.removeAll()` (single-slot semantics) -> device A is restored to
    // its quiet level, not 0.8 (RED).
    func testAnOwedRestoreSurvivesADictationOnAnotherDevice() {
        let (fake, duck) = rig()
        fake.device = (id: 76, uid: "A")
        duck.begin(generation: 1)
        fake.refusedWrites = 2
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001)

        fake.device = (id: 77, uid: "B")
        fake.level = 0.6
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.6, accuracy: 0.0001, "B gets its own level, not A's owed one")

        fake.device = (id: 76, uid: "A")
        fake.level = quiet // A is still as quiet as the duck left it
        duck.begin(generation: 3)
        duck.end(generation: 3)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "A's owed original level survived B")
    }

    // A user-set zero mid-dictation is still faded back: restore wins even
    // over a silence the user asked for during those seconds.
    func testAUserSetZeroDuringDictationIsStillRestored() {
        let (fake, duck) = rig(level: 0.1)
        duck.begin(generation: 1)
        fake.level = 0 // the user muted the output themselves
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.1, accuracy: 0.0001,
                       "restore wins: the pre-duck level comes back over the user's silence")
    }

    // F10 — an output that applies volume asynchronously (AirPods, ramping
    // USB DACs) answers reads during the ramp with the PRE-WRITE level;
    // the confirm looks again after a settle instead of trusting one
    // read, so the restore lands and is confirmed.
    func testAnAsyncDeviceRestoresTheExactPriorLevel() {
        let (fake, duck) = rig()
        fake.asyncLag = true
        duck.begin(generation: 1)
        fake.settleReads()
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001,
                       "the write landed even though early reads did not show it")
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
    }

    // A quantizing device cannot hold a tiny target at all — the nearest
    // step IS 0, inside the confirm tolerance. That is as restored as the
    // device can get: accepted writes, nothing is an error.
    func testAQuantizedNearSilentRestoreIsAsConfirmedAsTheDeviceGets() {
        var errors: [String] = []
        let (fake, duck) = rig(level: 0.015) { errors.append($0) }
        fake.quantum = 1.0 / 16
        duck.begin(generation: 1)
        XCTAssertEqual(fake.level, 0, "the grid snapped the near-silent target to nothing")
        duck.end(generation: 1)
        XCTAssertEqual(errors, [], "a snapped-to-0 restore is inside the confirm tolerance")
    }
}

final class SoundWhileDictatingSettingTests: XCTestCase {
    // F3 — migration: the v0.1.24 bool, off, means the user opted out of sound
    // handling; it maps to "Don't Touch". Mutation: in
    // SoundWhileDictatingSetting.mode map legacy false to .pauseMusic -> RED.
    func testTheLegacyOffMigratesToDontTouch() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SoundWhileDictatingSetting.legacyKey)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .dontTouch)
        XCTAssertNil(defaults.object(forKey: SoundWhileDictatingSetting.legacyKey),
                     "the old key is read once, then gone")
        XCTAssertEqual(defaults.string(forKey: SoundWhileDictatingSetting.defaultsKey), "dontTouch",
                       "and the pick is stored under the new key")
    }

    func testTheLegacyOnAndItsAbsenceMigrateToPauseMusic() {
        for legacy: Bool? in [true, nil] {
            let (defaults, suite) = freshDefaults()
            if let legacy { defaults.set(legacy, forKey: SoundWhileDictatingSetting.legacyKey) }
            XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .pauseMusic,
                           "legacy \(legacy == nil ? "absent" : "on") keeps today's behaviour")
            XCTAssertNil(defaults.object(forKey: SoundWhileDictatingSetting.legacyKey))
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testAStoredModeWinsOverTheLegacyKey() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("lowerAllSound", forKey: SoundWhileDictatingSetting.defaultsKey)
        defaults.set(false, forKey: SoundWhileDictatingSetting.legacyKey)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
        XCTAssertNil(defaults.object(forKey: SoundWhileDictatingSetting.legacyKey))
    }

    func testAGarbageStoredValueFallsBackToTheMigration() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bogus", forKey: SoundWhileDictatingSetting.defaultsKey)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .pauseMusic)
    }
}

final class SoundWhileDictatingRunnerTests: XCTestCase {
    private func rig(mode: @escaping () -> SoundWhileDictating)
        -> (SoundWhileDictatingRunner, FakeMediaPlayer, FakeSystemVolume) {
        let music = FakeMediaPlayer("music", .playing)
        let fake = FakeSystemVolume()
        let duck = VolumeDuckCoordinator(volume: fake, stepDelay: 0)
        let runner = SoundWhileDictatingRunner(pause: MediaPauseCoordinator(players: [music], retryDelay: 0),
                                               duck: duck, mode: mode)
        return (runner, music, fake)
    }

    // The menu pick, read at every dictation start: pause the players, lower
    // everything, or leave all sound alone.
    func testEachModeRunsItsOwnAction() {
        var mode = SoundWhileDictating.pauseMusic
        let (runner, music, fake) = rig { mode }

        runner.dictationStateChanged(.recording); runner.drain()
        XCTAssertEqual(music.current, .paused)
        XCTAssertEqual(fake.writes, [], "pause mode never touches the volume")
        runner.dictationStateChanged(.idle); runner.drain()

        mode = .lowerAllSound
        runner.dictationStateChanged(.recording); runner.drain()
        XCTAssertEqual(fake.level, 0.8 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001)
        XCTAssertEqual(music.pauseCalls, 1, "duck mode never touches the players")
        runner.dictationStateChanged(.idle); runner.drain()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)

        mode = .dontTouch
        runner.dictationStateChanged(.recording); runner.drain()
        XCTAssertEqual([music.pauseCalls, music.playCalls], [1, 1])
        XCTAssertEqual(fake.level, 0.8)
        runner.dictationStateChanged(.idle); runner.drain()
    }

    // Changing the pick mid-dictation must still give back what that dictation
    // took: the ending ends BOTH actions, so the generation decides, not the
    // mode that happens to be stored when it ends.
    func testAModeChangeMidDictationStillGivesItBack() {
        var mode = SoundWhileDictating.lowerAllSound
        let (runner, music, fake) = rig { mode }
        runner.dictationStateChanged(.recording); runner.drain()
        mode = .pauseMusic
        runner.dictationStateChanged(.idle); runner.drain()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the duck this dictation took is restored")
        XCTAssertEqual(music.pauseCalls, 0, "and no pause was taken to give back")
    }

    // A hung volume call must not hold termination open: the timed drain gives
    // up, the unbounded one still joins, and the work completes on its queue.
    func testTheTimedDrainBoundsTheWaitAndThePlainOneJoins() {
        let (runner, _, fake) = rig { .lowerAllSound }
        fake.gate = DispatchSemaphore(value: 0)
        runner.dictationStateChanged(.recording)
        XCTAssertFalse(runner.drain(timeout: 0.05), "the queue is busy in the gated write")
        fake.gate?.signal()
        runner.drain()
        XCTAssertEqual(fake.level, 0.8 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001)
        runner.dictationStateChanged(.idle); runner.drain()
    }
}

/// The duck through the real DictationController: recording start is never
/// held by a fade, and every ending restores the level.
final class VolumeDuckJourneyTests: XCTestCase {
    private func rig(samples: Int) -> (DictationController, FakeRecorder, FakeSystemVolume, SoundWhileDictatingRunner) {
        let fake = FakeSystemVolume()
        let duck = VolumeDuckCoordinator(volume: fake, stepDelay: 0)
        let runner = SoundWhileDictatingRunner(pause: MediaPauseCoordinator(players: []),
                                               duck: duck, mode: { .lowerAllSound })
        let recorder = FakeRecorder()
        recorder.samples = [Float](repeating: 0.1, count: samples)
        let controller = DictationController(recorder: recorder, output: FakeOutput(), mode: .hold) { _ in "hello" }
        controller.onState = { runner.dictationStateChanged($0) }
        return (controller, recorder, fake, runner)
    }

    @MainActor
    func testHoldDucksOnKeyDownAndRestoresOnRelease() async {
        let (c, _, fake, runner) = rig(samples: 16000)
        c.keyDown()
        runner.drain()
        XCTAssertEqual(fake.level, 0.8 * VolumeDuckCoordinator.duckFraction, accuracy: 0.001)
        c.keyUp()
        runner.drain()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        try? await Task.sleep(nanoseconds: 300_000_000)
        runner.drain()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
    }

    // The fade runs off the main thread: a volume call that takes a second
    // still leaves keyDown — and recorder.start() — unblocked.
    func testKeyDownNeverWaitsForTheFade() {
        let (c, _, fake, runner) = rig(samples: 16000)
        fake.gate = DispatchSemaphore(value: 0)
        let started = Date()
        c.keyDown()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3,
                          "keyDown must reach recorder.start() without waiting on the volume")
        XCTAssertEqual(c.state, .recording)
        fake.gate?.signal()
        runner.drain()
        c.cancel()
        runner.drain()
    }

    // A start that fails: the queued begin is undone by the queued end —
    // generation-owned, nothing left ducked.
    @MainActor
    func testAFailedStartLeavesNothingDucked() {
        let (c, recorder, fake, runner) = rig(samples: 16000)
        recorder.startError = NSError(domain: "mic", code: 1)
        c.keyDown()
        runner.drain()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
    }
}

/// The app-glue files that cannot run here are checked for what they must
/// hand to the tested wiring — mode pass-through and the bounded quit drain.
final class SoundWhileDictatingAppGlueTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(name)
        return try String(contentsOf: path, encoding: .utf8)
    }

    func testTheSystemSideHandsTheRealPiecesToTheWiring() throws {
        let source = try source("Sources/OxSayDictation/SoundWhileDictatingSystem.swift")
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        for needle in ["SoundWhileDictatingWiring.makeRunner(", "isRunning: isRunning",
                       "volume: CoreAudioSystemVolume()", "defaults: .standard",
                       "onPermissionDenied: onPermissionDenied", "category: \"media\""] {
            XCTAssertTrue(source.contains(needle), "SoundWhileDictatingSystem.makeRunner must pass `\(needle)`")
        }
    }

    // The mode the menu stores must reach the runner, and the real volume the
    // duck. Mutation: in SoundWhileDictatingWiring.makeRunner replace the
    // `mode:` closure with `{ .pauseMusic }` (or drop `duck:`) -> RED.
    func testTheWiringPassesTheModeAndTheVolume() throws {
        let source = try source("Sources/DictationCore/SoundWhileDictatingWiring.swift")
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        for needle in ["mode: { SoundWhileDictatingSetting.mode(defaults) }",
                       "VolumeDuckCoordinator(volume:", "duck: duck"] {
            XCTAssertTrue(source.contains(needle), "SoundWhileDictatingWiring.makeRunner must contain `\(needle)`")
        }
    }

    // F6 — the quit path: inside applicationWillTerminate the runner gets the
    // .idle transition and a BOUNDED drain; the unbounded drain before this
    // fix could hold the quit for ~9.5 s. Mutation: in AppDelegate
    // applicationWillTerminate call `drain()` instead of `drain(timeout: 3)`
    // -> RED.
    func testApplicationWillTerminateForwardsIdleAndDrainsBounded() throws {
        let source = try source("Sources/OxSayDictation/AppDelegate.swift")
        guard let start = source.range(of: "func applicationWillTerminate"),
              let end = source[start.upperBound...].range(of: "\n    }\n") else {
            XCTFail("applicationWillTerminate not found")
            return
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("soundWhileDictating.dictationStateChanged(.idle)"),
                      "quitting mid-dictation must end the runner's dictation")
        XCTAssertTrue(body.contains("soundWhileDictating.drain(timeout:"),
                      "the quit drain must be bounded — a hung player cannot hold termination open")
        XCTAssertFalse(body.contains(".drain()"),
                       "the unbounded drain must not come back")
        let wiring = source.components(separatedBy: .newlines).filter { $0.contains("controller.onState =") }
        XCTAssertEqual(wiring.count, 1)
        XCTAssertTrue(wiring.first?.contains("soundWhileDictating.dictationStateChanged(state)") ?? false,
                      "every controller state must reach the runner")
    }
}
