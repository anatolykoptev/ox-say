import Foundation
import XCTest
@testable import DictationCore

/// A fake output device behind the duck: one device with a level, settable
/// flag and mute; reassign `device` for a replug (new AudioObjectID), set
/// `gone` for an unplug. Writes are recorded and applied like the server.
final class FakeSystemVolume: SystemVolume {
    var device: (id: UInt32, uid: String?)? = (id: 76, uid: "fake-output")
    var gone = false
    /// The device is there (its UID resolves) but its volume cannot be read.
    var unreadable = false
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
    /// A second, present output that is not the default: reads, writes and
    /// UID lookup reach it by its id.
    var other: (id: UInt32, uid: String, level: Float)?

    func defaultDevice() -> (id: UInt32, uid: String?)? { gone ? nil : device }
    func isSettable(_: UInt32) -> Bool { settable }
    func volume(_ id: UInt32) -> Float? {
        if let other, other.id == id { return other.level }
        guard !gone, !unreadable, let device, device.id == id else { return nil }
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
    func setVolume(_ id: UInt32, _ newLevel: Float) -> Bool {
        if other?.id == id { other?.level = newLevel; writes.append(newLevel); return true }
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
        if let other, other.uid == uid { return other.id }
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
    private func rig(level: Float = 0.8, logError: @escaping (String) -> Void = { _ in },
                     now: @escaping () -> Date = Date.init)
        -> (FakeSystemVolume, VolumeDuckCoordinator) {
        let fake = FakeSystemVolume()
        fake.level = level
        return (fake, VolumeDuckCoordinator(volume: fake, stepDelay: 0, logError: logError, now: now))
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
    // At 0.06 the still-ducked level sits inside the confirm tolerance of the
    // target, so only the accepted-write conditions in `restore` tell a retry
    // that landed from a read that merely looks close (#200.4).
    // Mutations: in VolumeDuckCoordinator.restore make the first condition
    // `fade(...) || true` -> the 0.06 case never retries and stays at 0.009;
    // make the second `volume.setVolume(...) || true` -> only
    // testATinyLevelRefusedRestoreIsNotConfirmed (both writes refused) sees it.
    func testARefusedRestoreWriteIsRetriedOnce() {
        for level: Float in [0.8, 0.06] {
            var errors: [String] = []
            let (fake, duck) = rig(level: level) { errors.append($0) }
            duck.begin(generation: 1)
            fake.refusedWrites = 1
            duck.end(generation: 1)
            XCTAssertEqual(fake.level, level, accuracy: 0.0001, "the retry lands it (from \(level))")
            XCTAssertEqual(errors, [], "a recovered restore is not an error (from \(level))")
        }
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

    // The device is gone, or answers but cannot be read: the restore stays
    // owed, and each is one error line without the device's name or any
    // content. Mutation: delete either logError line in
    // VolumeDuckCoordinator.restore -> the matching test goes RED.
    func testAGoneDeviceRestoreIsLoggedWithoutContent() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        duck.begin(generation: 1)
        fake.gone = true
        duck.end(generation: 1)
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertTrue(errors.first?.contains("gone") ?? false, "\(errors)")
        XCTAssertFalse(errors.first?.contains("fake-output") ?? true, "no device name in the log")
    }

    func testAnUnreadableDeviceRestoreIsLoggedWithoutContent() {
        var errors: [String] = []
        let (fake, duck) = rig { errors.append($0) }
        duck.begin(generation: 1)
        fake.unreadable = true
        duck.end(generation: 1)
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertTrue(errors.first?.contains("cannot be read") ?? false, "\(errors)")
        XCTAssertFalse(errors.first?.contains("fake-output") ?? true, "no device name in the log")
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
        XCTAssertFalse(duck.begin(generation: 1), "a half-lowered output is not handled: the caller also pauses")
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

    // #200.2 — "still as quiet as the duck left it" is relative to the duck:
    // pre 0.8 ducks to 0.12, and a user who has since set 0.19 chose that
    // level; the old fixed margin (ducked + 0.0725 = 0.1925) took it for the
    // leftover and lifted it to 0.8. A level a little above the duck (0.17)
    // is still the leftover.
    // Mutation: in VolumeDuckCoordinator.stillQuietBound return
    // `ducked + confirmTolerance` -> the 0.19 case restores to 0.8 (RED).
    func testALevelPastOneAndAHalfTimesTheDuckIsTheUsersNotTheLeftover() {
        for (set, back): (Float, Float) in [(0.19, 0.19), (0.17, 0.8)] {
            let (fake, duck) = rig()
            duck.begin(generation: 1)
            fake.refusedWrites = 2
            duck.end(generation: 1)
            fake.level = set
            duck.begin(generation: 2)
            duck.end(generation: 2)
            XCTAssertEqual(fake.level, back, accuracy: 0.0001,
                           "a level of \(set) after a duck to \(quiet) must come back as \(back)")
        }
    }

    // A grid output rounds a small duck UP to the next step (pre 0.25 ->
    // computed 0.0375 -> held 0.0625), more than 1.5x the computed level:
    // that is still the leftover, owed its original 0.25.
    // Mutation: in stillQuietBound drop the second operand of `max` -> the
    // quiet 0.0625 is taken for the user's and restored to itself (RED).
    func testAGridSnappedDuckIsStillTheLeftover() {
        let (fake, duck) = rig(level: 0.25)
        fake.quantum = 1.0 / 16
        duck.begin(generation: 1)
        XCTAssertEqual(fake.level, 0.0625, accuracy: 0.0001, "the grid held the duck above its computed level")
        fake.refusedWrites = 2
        duck.end(generation: 1)
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.25, accuracy: 0.0001, "the original level is still owed")
    }

    // #216.2 — a restore that stopped partway leaves the output between the
    // duck and the original (0.256 of 0.8 -> 0.12): above `stillQuietBound`,
    // but it is the failed restore's level, not the user's. The next
    // dictation still owes the original 0.8.
    // Mutation: in owedPreDuck delete the `entry.landed` branch (the
    // `abs(level - entry.landed)` guard) -> the 0.256 is taken as the user's
    // and stays (RED).
    func testAPartialRestoreIsStillOwedItsOriginalLevel() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        fake.refuseWritesFrom = fake.writes.count + 1 // the first restore step lands, the rest are refused
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.256, accuracy: 0.001, "the restore stopped at its first step")
        fake.refuseWritesFrom = nil
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the original level is still owed")
    }

    // The partial level must be where the failed restore left it: a user who
    // moved the output since (0.256 -> 0.35) chose that level.
    func testAUserLevelAfterAPartialRestoreIsTheirOwn() {
        let (fake, duck) = rig()
        duck.begin(generation: 1)
        fake.refuseWritesFrom = fake.writes.count + 1
        duck.end(generation: 1)
        fake.refuseWritesFrom = nil
        fake.level = 0.35
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.35, accuracy: 0.0001)
    }

    // #200.1 — an owed restore is forgotten after `owedLifetime`: the output
    // that sits at the duck's level five minutes on was most likely put there
    // by the user. Mutation: in owedPreDuck delete the `owedLifetime` guard
    // -> the aged entry lifts the output to 0.8 (RED).
    func testAnOwedRestoreExpires() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let (fake, duck) = rig(now: { clock })
        duck.begin(generation: 1)
        fake.refusedWrites = 2
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001)
        clock = clock.addingTimeInterval(VolumeDuckCoordinator.owedLifetime + 1)
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, quiet, accuracy: 0.001,
                       "the aged entry is dropped: the level read is the user's own")
    }

    func testAnOwedRestoreIsStillHonouredJustBeforeItExpires() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        let (fake, duck) = rig(now: { clock })
        duck.begin(generation: 1)
        fake.refusedWrites = 2
        duck.end(generation: 1)
        clock = clock.addingTimeInterval(VolumeDuckCoordinator.owedLifetime - 1)
        duck.begin(generation: 2)
        duck.end(generation: 2)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "inside the lifetime the original level comes back")
    }

    // #216.3 — an owed entry that expires, is claimed or is overtaken by the
    // user is said once, without content (no level, no device).
    // Mutation: in owedPreDuck drop the three logError calls -> RED.
    func testOwedEntriesAreLoggedWhenTheyExpireOrAreClaimed() {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        var errors: [String] = []
        let (fake, duck) = rig(logError: { errors.append($0) }, now: { clock })
        func failedDuck(_ g: Int) {
            duck.begin(generation: g)
            fake.refusedWrites = 2
            duck.end(generation: g)
        }
        failedDuck(1)
        errors.removeAll()
        clock = clock.addingTimeInterval(VolumeDuckCoordinator.owedLifetime + 1)
        duck.begin(generation: 2)
        XCTAssertEqual(errors.count, 1, "expiry: \(errors)")
        XCTAssertTrue(errors.first?.contains("expired") ?? false, "\(errors)")
        duck.end(generation: 2)

        fake.level = 0.8
        failedDuck(3)
        errors.removeAll()
        duck.begin(generation: 4)
        XCTAssertEqual(errors.count, 1, "claim: \(errors)")
        XCTAssertTrue(errors.first?.contains("claimed") ?? false, "\(errors)")
        duck.end(generation: 4)

        fake.level = 0.8
        failedDuck(5)
        errors.removeAll()
        fake.level = 0.5
        duck.begin(generation: 6)
        XCTAssertEqual(errors.count, 1, "overtaken: \(errors)")
        XCTAssertTrue(errors.first?.contains("dropped") ?? false, "\(errors)")
        XCTAssertFalse(errors.joined().contains("fake-output"))
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

final class InMemoryDuckRecordStore: DuckRecordStore {
    var record: DuckRecord?
    func load() -> DuckRecord? { record }
    func save(_ record: DuckRecord) { self.record = record }
    func clear() { record = nil }
}

/// Item: a crash or SIGKILL while ducked must not leave the output at 15%.
final class VolumeDuckRecoveryTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private var errors: [String] = []

    private func rig(level: Float = 0.8) -> (FakeSystemVolume, InMemoryDuckRecordStore, VolumeDuckCoordinator) {
        let fake = FakeSystemVolume()
        fake.level = level
        let store = InMemoryDuckRecordStore()
        return (fake, store, VolumeDuckCoordinator(volume: fake, stepDelay: 0, settleDelay: 0,
                                                   logError: { [unowned self] in self.errors.append($0) },
                                                   now: { [unowned self] in self.clock }, records: store))
    }

    /// A record the duck left `age` seconds before the rig's clock.
    private func record(uid: String = "fake-output", age: TimeInterval = 30) -> DuckRecord {
        DuckRecord(uid: uid, preDuck: 0.8, ducked: 0.12, savedAt: clock.addingTimeInterval(-age))
    }

    func testBeginReportsWhetherTheOutputWasLowered() {
        let (_, _, ducked) = rig()
        XCTAssertTrue(ducked.begin(generation: 1))

        let (unsettable, _, a) = rig(); unsettable.settable = false
        XCTAssertFalse(a.begin(generation: 1), "an output without a software volume is not handled")
        let (gone, _, b) = rig(); gone.gone = true
        XCTAssertFalse(b.begin(generation: 1), "no default device is not handled")
        let (muted, _, c) = rig(); muted.muted = true
        XCTAssertTrue(c.begin(generation: 1), "a muted output has nothing audible to lower")
    }

    func testTheDebtIsRecordedWhileDuckedAndClearedAfterAConfirmedRestore() {
        let (fake, store, duck) = rig()
        duck.begin(generation: 1)
        let record = store.record
        XCTAssertEqual(record?.uid, "fake-output")
        XCTAssertEqual(record?.preDuck ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(record?.ducked ?? 0, 0.12, accuracy: 0.0001)
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        XCTAssertNil(store.record, "a confirmed restore clears the debt")
    }

    func testAnUnconfirmedRestoreKeepsTheDebt() {
        let (fake, store, duck) = rig()
        duck.begin(generation: 1)
        fake.refuseWritesFrom = fake.writes.count
        duck.end(generation: 1)
        XCTAssertNotNil(store.record)
    }

    // Mutation: in VolumeDuckCoordinator.recoverInterrupted return at once
    // (skip the launch restore) -> RED.
    func testALaunchAfterACrashGivesTheLevelBack() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record()
        duck.recoverInterrupted()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        XCTAssertNil(store.record)
    }

    func testALaunchLeavesAVolumeTheUserMovedAndDropsTheRecord() {
        let (fake, store, duck) = rig(level: 0.5)
        store.record = record()
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    // #265 leftover: a record whose device is absent (unplugged AirPods) is
    // kept for a later launch, not dropped; nothing is written. The 24 h
    // lifetime still bounds it.
    // Mutation: in recoverInterrupted make the absent-device branch
    // `records?.clear()` -> RED.
    func testALaunchWhileTheDeviceIsAbsentKeepsTheRecord() {
        let (fake, store, duck) = rig(level: 0.12)
        let kept = record(uid: "airpods")
        store.record = kept
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertEqual(store.record, kept, "the device may be back at a later launch")
        XCTAssertEqual(errors.count, 1, "kept loudly, once: \(errors)")
        XCTAssertFalse(errors.joined().contains("airpods"))
    }

    func testAnAbsentDevicesRecordStillDiesOfAge() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(uid: "airpods", age: VolumeDuckCoordinator.recordLifetime + 1)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    // The ducked device is present but not the default output: it is found by
    // UID and given its level back there.
    // Mutation: in recoverInterrupted require `device.uid == record.uid` of
    // the default device again -> the level stays ducked (RED).
    func testALaunchRestoresADuckedDeviceThatIsNotTheDefault() {
        let (fake, store, duck) = rig(level: 0.5)
        fake.other = (id: 90, uid: "airpods", level: 0.12)
        store.record = record(uid: "airpods")
        duck.recoverInterrupted()
        XCTAssertEqual(fake.other?.level ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(fake.level, 0.5, accuracy: 0.0001, "the default output is left alone")
        XCTAssertNil(store.record)
    }

    func testALaunchLeavesANonDefaultDeviceTheUserMoved() {
        let (fake, store, duck) = rig(level: 0.5)
        fake.other = (id: 90, uid: "airpods", level: 0.4)
        store.record = record(uid: "airpods")
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    func testALaunchWithoutARecordWritesNothing() {
        let (fake, _, duck) = rig(level: 0.12)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
    }

    // #265 item 1: a device that reports a settable volume but refuses the
    // first write was not ducked. begin says so (the caller pauses the players
    // instead) and no debt, record or owed restore is left for a duck that
    // never happened. Mutation: VolumeDuckCoordinator.begin drop the refused
    // first write (`_ = fade(...)`, `return true`) -> RED.
    func testARefusedFirstWriteIsNotHandledAndLeavesNoDebt() {
        let (fake, store, duck) = rig()
        fake.refusedWrites = 1
        XCTAssertFalse(duck.begin(generation: 1), "a refused write did not lower the output")
        XCTAssertNil(store.record, "no duck happened, so nothing is owed")
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        let before = fake.writes.count
        duck.end(generation: 1)
        XCTAssertEqual(fake.writes.count, before, "the end of a dictation that never ducked writes nothing")
    }

    // The refused begin must not eat the owed restore of an earlier failed
    // one: the next working dictation still gives back the original level.
    func testARefusedFirstWriteKeepsAnEarlierOwedRestore() {
        let (fake, _, duck) = rig()
        XCTAssertTrue(duck.begin(generation: 1))
        fake.refuseWritesFrom = fake.writes.count
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.12, accuracy: 0.0001, "the restore failed: the output sits at the duck")
        fake.refuseWritesFrom = nil
        fake.refusedWrites = 1
        XCTAssertFalse(duck.begin(generation: 2))
        XCTAssertTrue(duck.begin(generation: 3))
        duck.end(generation: 3)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "the owed level survives the refused begin")
    }

    // #265 item 2: the store holds one record. A confirmed restore of one
    // device must not clear the record of another. Mutation: forgetOwed
    // clears the store unconditionally -> RED.
    func testAConfirmedRestoreLeavesAnotherDevicesRecord() {
        let (fake, store, duck) = rig()
        XCTAssertTrue(duck.begin(generation: 1))
        let other = record(uid: "other-output")
        store.record = other
        duck.end(generation: 1)
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        XCTAssertEqual(store.record, other, "the other device's debt is not ours to forget")
    }

    func testAConfirmedRestoreClearsItsOwnRecord() {
        let (_, store, duck) = rig()
        XCTAssertTrue(duck.begin(generation: 1))
        duck.end(generation: 1)
        XCTAssertNil(store.record)
    }

    // #265 item 3: the record carries when the duck was taken, and a record
    // older than recordLifetime is dropped without a write. Mutation:
    // recoverInterrupted ignore the age -> RED.
    func testTheDuckStampsItsRecord() {
        let (_, store, duck) = rig()
        XCTAssertTrue(duck.begin(generation: 1))
        XCTAssertEqual(store.record?.savedAt, clock)
    }

    // A crash or power loss followed by the next working day's launch must
    // still give the level back; only a day-old record is dropped.
    // Mutation: recordLifetime back to 10 minutes -> RED (8 hours).
    func testACrashIsRecoveredByALaterLaunch() {
        for age: TimeInterval in [11 * 60, 8 * 3600] {
            let (fake, store, duck) = rig(level: 0.12)
            store.record = record(age: age)
            duck.recoverInterrupted()
            XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "a record \(age) s old is recovered")
            XCTAssertNil(store.record)
        }
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(age: 25 * 3600)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [], "after a day the user has lived with that level")
        XCTAssertNil(store.record)
    }

    // A small backwards clock step must not drop a fresh record.
    // Mutation: no skew tolerance (elapsed must be >= 0) -> RED.
    func testASmallBackwardsClockStepStillRecovers() {
        for age: TimeInterval in [-2, -4 * 60] {
            let (fake, store, duck) = rig(level: 0.12)
            store.record = record(age: age)
            duck.recoverInterrupted()
            XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001, "elapsed \(-age) s negative is tolerated")
        }
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(age: -10 * 60)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    // Dropping a record is said once, without content.
    // Mutation: drop the logError in recoverInterrupted -> RED.
    func testADroppedRecordIsLogged() {
        let (_, store, duck) = rig(level: 0.12)
        store.record = record(age: 25 * 3600)
        duck.recoverInterrupted()
        XCTAssertEqual(errors.count, 1)
        store.record = DuckRecord(uid: "fake-output", preDuck: 0.8, ducked: 0.12)
        duck.recoverInterrupted()
        XCTAssertEqual(errors.count, 2, "an unstamped record is dropped loudly too")
        XCTAssertFalse(errors.joined().contains("fake-output"), "no device id in the log")
    }

    // A refused begin never touches the store: an earlier record that is
    // still owed survives. Mutation: save the record before the first write
    // -> RED.
    func testARefusedBeginKeepsAnEarlierPersistedRecord() {
        let (fake, store, duck) = rig()
        let earlier = record(age: 60)
        store.record = earlier
        fake.refusedWrites = 1
        XCTAssertFalse(duck.begin(generation: 1))
        XCTAssertEqual(store.record, earlier)
    }

    func testAStaleRecordIsDroppedAndTheLevelLeftAlone() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(age: VolumeDuckCoordinator.recordLifetime + 1)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [], "an old record must not set the volume")
        XCTAssertNil(store.record)
    }

    func testARecordJustInsideTheLifetimeStillRecovers() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(age: VolumeDuckCoordinator.recordLifetime - 1)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.level, 0.8, accuracy: 0.0001)
        XCTAssertNil(store.record)
    }

    func testARecordWithoutATimestampIsStale() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = DuckRecord(uid: "fake-output", preDuck: 0.8, ducked: 0.12)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    func testARecordFromTheFutureIsStale() {
        let (fake, store, duck) = rig(level: 0.12)
        store.record = record(age: -3600)
        duck.recoverInterrupted()
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(store.record)
    }

    func testTheDefaultsStoreRoundTripsAndReadsALegacyRecordAsUnstamped() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDuckRecordStore(defaults: defaults)
        let stamped = DuckRecord(uid: "u", preDuck: 0.75, ducked: 0.1125,
                                 savedAt: Date(timeIntervalSince1970: 1_800_000_123.456))
        store.save(stamped)
        XCTAssertEqual(store.load(), stamped)
        // A record written by a build before the timestamp existed.
        defaults.removeObject(forKey: UserDefaultsDuckRecordStore.savedAtKey)
        XCTAssertNotNil(store.load(), "an old record still loads")
        XCTAssertNil(store.load()?.savedAt)
    }

    func testTheDefaultsStoreRoundTripsInAPrivateSuite() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDuckRecordStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(DuckRecord(uid: "u", preDuck: 0.75, ducked: 0.1125))
        XCTAssertEqual(store.load(), DuckRecord(uid: "u", preDuck: 0.75, ducked: 0.1125))
        store.clear()
        XCTAssertNil(store.load())
    }
}

final class SoundWhileDictatingSettingTests: XCTestCase {
    private let key = SoundWhileDictatingSetting.defaultsKey
    private let marker = SoundWhileDictatingSetting.defaultV2Key
    private let legacy = SoundWhileDictatingSetting.legacyKey

    // Fresh install: Lower All Sound is the default (a browser plays too).
    // Mutation: in SoundWhileDictatingSetting.mode default `.lowerAllSound`
    // -> `.pauseMusic` -> RED.
    func testNothingStoredIsLowerAllSound() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
        XCTAssertEqual(defaults.string(forKey: key), "lowerAllSound")
        XCTAssertTrue(defaults.bool(forKey: marker), "a fresh install is already on the new default")
    }

    // v0.1.25+ wrote "pauseMusic" on first read, so it is not a choice.
    // Mutation: delete the migration branch in mode() -> RED.
    func testAStoredPauseMusicWithoutTheMarkerMigratesOnce() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pauseMusic", forKey: key)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
        XCTAssertEqual(defaults.string(forKey: key), "lowerAllSound")
        XCTAssertTrue(defaults.bool(forKey: marker))
    }

    // After the migration a user's Pause Music pick sticks. Mutation: make
    // mode() ignore the marker (migrate every stored pauseMusic) -> RED.
    func testAPauseMusicPickAfterTheMigrationSticks() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pauseMusic", forKey: key)
        defaults.set(true, forKey: marker)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .pauseMusic)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .pauseMusic)
    }

    // The pick path itself must set the marker: a pick made before mode()
    // ever ran must not be migrated away on the next read.
    func testChoosingPauseMusicSticksEvenOnAnUnmigratedStore() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pauseMusic", forKey: key)
        SoundWhileDictatingSetting.choose(.pauseMusic, in: defaults)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .pauseMusic)
    }

    func testDontTouchAndLowerAllAreKeptAndDontTouchSurvivesLaterReads() {
        for mode in [SoundWhileDictating.dontTouch, .lowerAllSound] {
            let (defaults, suite) = freshDefaults()
            defaults.set(mode.rawValue, forKey: key)
            XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), mode)
            XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), mode)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    // A kept pick must also set the marker, else a later Pause Music pick
    // written straight to the key would be migrated away.
    func testKeepingAStoredModeSetsTheMarker() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dontTouch", forKey: key)
        _ = SoundWhileDictatingSetting.mode(defaults)
        XCTAssertTrue(defaults.bool(forKey: marker))
    }

    // F3 — the v0.1.24 bool, off, means the user opted out of sound handling.
    // Mutation: in mode() map legacy false to the default -> RED.
    func testTheLegacyOffMigratesToDontTouch() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: legacy)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .dontTouch)
        XCTAssertNil(defaults.object(forKey: legacy), "the old key is read once, then gone")
        XCTAssertEqual(defaults.string(forKey: key), "dontTouch")
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .dontTouch)
    }

    func testTheLegacyOnMigratesToLowerAllSound() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: legacy)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
        XCTAssertNil(defaults.object(forKey: legacy))
    }

    func testAStoredModeWinsOverTheLegacyKey() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("lowerAllSound", forKey: key)
        defaults.set(false, forKey: legacy)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
        XCTAssertNil(defaults.object(forKey: legacy))
    }

    func testAGarbageStoredValueFallsBackToTheDefault() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bogus", forKey: key)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(defaults), .lowerAllSound)
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

/// The code of `AppDelegate.applicationWillTerminate` — its body with the
/// comments taken out, so a name that only a comment mentions is not found.
func applicationWillTerminateCode(file: String = #filePath) throws -> String {
    let path = URL(fileURLWithPath: file)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/OxSayDictation/AppDelegate.swift")
    let source = try String(contentsOf: path, encoding: .utf8)
    guard let start = source.range(of: "func applicationWillTerminate"),
          let end = source[start.upperBound...].range(of: "\n    }\n") else {
        throw NSError(domain: "applicationWillTerminate not found", code: 1)
    }
    var code = String(source[start.upperBound..<end.lowerBound])
    for pattern in ["/\\*[\\s\\S]*?\\*/", "//[^\\n]*"] {
        code = code.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return code
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

    private func stripComments(_ text: String) -> String {
        var code = text
        for pattern in ["/\\*[\\s\\S]*?\\*/", "//[^\\n]*"] {
            code = code.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return code
    }

    // A menu pick must go through `choose` (it sets the default-V2 marker); a
    // direct write of the key would be migrated away on the next read.
    // Mutation: in AppDelegate.pickSoundMode put back
    // `UserDefaults.standard.set(mode.rawValue, forKey: SoundWhileDictatingSetting.defaultsKey)` -> RED.
    func testThePickGoesThroughChooseAndNothingElseWritesTheKey() throws {
        let app = stripComments(try source("Sources/OxSayDictation/AppDelegate.swift"))
        guard let start = app.range(of: "func pickSoundMode"),
              let end = app[start.upperBound...].range(of: "\n    }\n") else {
            return XCTFail("pickSoundMode not found")
        }
        let body = String(app[start.upperBound..<end.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(body.contains("SoundWhileDictatingSetting.choose("),
                      "pickSoundMode must store the pick through SoundWhileDictatingSetting.choose")

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 10, "the source walk found the tree")
        for file in files where file.lastPathComponent != "SoundWhileDictating.swift" {
            let code = stripComments(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(code.contains("SoundWhileDictatingSetting.defaultsKey"),
                           "\(file.lastPathComponent) must not touch the stored key; use choose/mode")
            XCTAssertFalse(code.contains("\"soundWhileDictating\""),
                           "\(file.lastPathComponent) must not spell the stored key")
        }
    }

    // A killed process must get its level back at the next launch, and the
    // "could not start" beep must not play into the restore ramp.
    // Mutation: delete the `soundWhileDictating.recoverInterruptedDuck()` line
    // in AppDelegate -> RED.
    func testTheAppRecoversADuckAtLaunchAndBeepsAfterTheRestore() throws {
        let app = stripComments(try source("Sources/OxSayDictation/AppDelegate.swift"))
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(app.contains("soundWhileDictating.recoverInterruptedDuck()"))
        XCTAssertTrue(app.contains("soundWhileDictating.afterSettled { NSSound.beep() }"))
    }

    // #265 leftover: the "busy" beep (a key press while transcribing) waits for
    // the restore ramp like the notice beep does.
    // Mutation: AppDelegate `controller.onBusy = { NSSound.beep() }` -> RED.
    func testTheBusyBeepWaitsForTheRestoreRamp() throws {
        let app = stripComments(try source("Sources/OxSayDictation/AppDelegate.swift"))
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(app.contains("controller.onBusy = { [weak self] in self?.soundWhileDictating.afterSettled { NSSound.beep() } }"))
    }

    // While a call is on, dictation must not lower the far side: the app hands
    // the meeting's call state to the runner, and the controller keeps it
    // current. Limitation: with auto-start off and nothing recording, the
    // watcher does not run, so a call is not seen.
    // Mutation: pass `{ false }` for `callActive:` in AppDelegate -> RED.
    func testTheAppPassesTheMeetingCallStateToTheRunner() throws {
        let app = MeetingWiringTests.stripComments(try source("Sources/OxSayDictation/AppDelegate.swift"))
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(app.contains("SoundWhileDictatingSystem.makeRunner(callActive: { [callActivity] in callActivity.isActive })"))
        XCTAssertTrue(app.contains("client: studioClient, defaults: .standard, callActivity: callActivity,"))
        let system = try source("Sources/OxSayDictation/SoundWhileDictatingSystem.swift")
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(system.contains("callActive: callActive,"))
        let wiring = try source("Sources/DictationCore/SoundWhileDictatingWiring.swift")
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(wiring.contains("callActive: callActive"))
    }

    // Mutation: MeetingController, delete the `host.callActivity.setRecording(` or
    // `setCallSeen(` update -> RED.
    func testTheMeetingControllerKeepsTheCallStateCurrent() throws {
        let c = MeetingWiringTests.stripComments(try source("Sources/OxSayDictation/MeetingController.swift"))
            .components(separatedBy: .whitespacesAndNewlines).joined(separator: " ")
        XCTAssertTrue(c.contains("host.callActivity.setRecording(current != nil)"))
        XCTAssertTrue(c.contains("host.callActivity.setCallSeen(tick.call != nil)"))
        XCTAssertTrue(c.contains("host.callActivity.setCallSeen(false)"))
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
    // -> RED. Comments are taken out first (#195.4): the call must be code.
    func testApplicationWillTerminateForwardsIdleAndDrainsBounded() throws {
        let source = try source("Sources/OxSayDictation/AppDelegate.swift")
        let body = try applicationWillTerminateCode()
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
