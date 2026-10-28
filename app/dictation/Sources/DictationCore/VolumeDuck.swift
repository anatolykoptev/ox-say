import Foundation

/// What "Lower All Sound" talks to: the system output volume. Each call is a
/// brief synchronous trip to the audio server, so they all run on the
/// runner's serial queue.
public protocol SystemVolume: AnyObject {
    /// The default output device: its AudioObjectID and persistent UID (`nil`
    /// when the device exposes none — an unconfirmed restore cannot be
    /// remembered for it then).
    func defaultDevice() -> (id: UInt32, uid: String?)?
    /// Whether the device's software volume can be written at all — false on
    /// outputs that have none (some HDMI and USB DACs).
    func isSettable(_ device: UInt32) -> Bool
    /// The virtual main output volume, 0…1; nil when it cannot be read (the
    /// device is gone).
    func volume(_ device: UInt32) -> Float?
    /// The output is muted.
    func isMuted(_ device: UInt32) -> Bool
    /// True when the audio server accepted the write.
    @discardableResult func setVolume(_ device: UInt32, _ level: Float) -> Bool
    /// The AudioObjectID a UID resolves to now; nil when the device is gone.
    func device(forUID uid: String) -> UInt32?
}

/// What a standing duck owes: the device (by persistent UID), the level to
/// give back and the level the duck left it at.
public struct DuckRecord: Equatable {
    public var uid: String
    public var preDuck: Float
    public var ducked: Float
    /// When the duck was taken; nil for a record written before the field
    /// existed, which counts as stale.
    public var savedAt: Date?

    public init(uid: String, preDuck: Float, ducked: Float, savedAt: Date? = nil) {
        self.uid = uid
        self.preDuck = preDuck
        self.ducked = ducked
        self.savedAt = savedAt
    }
}

/// Where the duck's debt survives a crash or a SIGKILL. One record.
public protocol DuckRecordStore: AnyObject {
    func load() -> DuckRecord?
    func save(_ record: DuckRecord)
    func clear()
}

/// The store the app uses: four keys in the given defaults.
public final class UserDefaultsDuckRecordStore: DuckRecordStore {
    public static let uidKey = "soundDuckPending.uid"
    public static let preDuckKey = "soundDuckPending.preDuck"
    public static let duckedKey = "soundDuckPending.ducked"
    public static let savedAtKey = "soundDuckPending.savedAt"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> DuckRecord? {
        guard let uid = defaults.string(forKey: Self.uidKey),
              defaults.object(forKey: Self.preDuckKey) != nil,
              defaults.object(forKey: Self.duckedKey) != nil else { return nil }
        let savedAt = defaults.object(forKey: Self.savedAtKey) as? Double
        return DuckRecord(uid: uid, preDuck: defaults.float(forKey: Self.preDuckKey),
                          ducked: defaults.float(forKey: Self.duckedKey),
                          savedAt: savedAt.map(Date.init(timeIntervalSince1970:)))
    }

    public func save(_ record: DuckRecord) {
        defaults.set(record.uid, forKey: Self.uidKey)
        defaults.set(record.preDuck, forKey: Self.preDuckKey)
        defaults.set(record.ducked, forKey: Self.duckedKey)
        if let savedAt = record.savedAt {
            defaults.set(savedAt.timeIntervalSince1970, forKey: Self.savedAtKey)
        } else {
            defaults.removeObject(forKey: Self.savedAtKey)
        }
    }

    public func clear() {
        for key in [Self.uidKey, Self.preDuckKey, Self.duckedKey, Self.savedAtKey] { defaults.removeObject(forKey: key) }
    }
}

/// "Lower All Sound": on the key down the default output fades to a fraction
/// of its level; on every ending it fades back to exactly the level it had.
/// Restore wins: a level the user picked during the few seconds of a
/// dictation loses to the restore, because an output left quiet forever is
/// the larger harm — and no comparison of levels can tell every device's
/// duck from a user change. A restore that could not be confirmed stays owed
/// in memory, per device, and is applied by the next dictation on that device
/// if the output is still as quiet as the duck left it. While a duck stands,
/// `{device uid, preDuck, ducked}` is kept in a `DuckRecordStore` and cleared
/// after a confirmed restore; a process that died mid-dictation finds it at
/// the next launch (`recoverInterrupted`) and gives the level back if the
/// output still sits at the ducked level.
///
/// Not thread safe: `SoundWhileDictatingRunner` feeds it from one serial
/// queue, where `begin` and `end` alternate per generation.
public final class VolumeDuckCoordinator {
    /// The ducked level is this fraction of the level at the key down.
    public static let duckFraction: Float = 0.15
    /// The grid of the volume keys: an output that snaps every write to it
    /// lands at most half a step (1/32) from the level it was asked to hold.
    private static let quantizationStep: Float = 1.0 / 16
    /// Room on top of the grid for float noise in the read-back.
    private static let readSlack: Float = 0.01
    /// How far a settled read may sit from the level it was asked to hold
    /// and still count as restored — generous enough for an output that
    /// snaps every write to a 1/16 grid (the volume keys' step) to land
    /// inside it from any computed target.
    public static let confirmTolerance: Float = quantizationStep + readSlack
    /// How long an unconfirmed restore stays owed: the next dictation on the
    /// device is usually within minutes; past this, a level that happens to
    /// match the duck is more likely the user's own than a leftover.
    public static let owedLifetime: TimeInterval = 5 * 60
    /// How long a persisted record stays good: a crash or power loss
    /// followed by the next working day's launch must still give the level
    /// back (the level-match check in `recoverInterrupted` is the real guard
    /// against a record that no longer applies); after a day the user has
    /// lived with that level, and an older record must never set it.
    public static let recordLifetime: TimeInterval = 24 * 60 * 60
    /// How far the clock may have stepped back since the record was written
    /// (NTP, a manual change) without the record counting as dated in the
    /// future.
    public static let clockSkewTolerance: TimeInterval = 5 * 60
    /// How many settle-spaced reads a confirm takes before giving up — an
    /// output that applies volume asynchronously can keep answering the old
    /// level for the first few.
    private static let confirmReads = 3

    /// What `begin` captured of the device it ducked: who owns the restore.
    private struct Duck {
        let generation: Int
        let deviceID: UInt32
        let uid: String?
        let preDuck: Float
        let ducked: Float
    }

    /// A restore that did not land: the level the device is owed, the level
    /// the duck left it at, and when the restore failed.
    private struct Owed {
        let preDuck: Float
        let ducked: Float
        let since: Date
    }

    private let volume: SystemVolume
    private let steps: Int
    private let stepDelay: TimeInterval
    private let settleDelay: TimeInterval
    private let log: (String) -> Void
    private let logError: (String) -> Void
    private let now: () -> Date
    private let records: DuckRecordStore?
    private var duck: Duck?
    /// Unconfirmed restores by device UID. Dies with the process.
    private var owed: [String: Owed] = [:]
    /// One log line per launch for outputs without a settable volume.
    private var unsettableLogged = false

    /// - `steps`/`stepDelay` shape the fade: 5 steps of 50 ms ≈ 250 ms.
    /// - `settleDelay` pauses before each confirm read, so an output that
    ///   applies volume asynchronously has landed the write first: 80 ms.
    /// - `log` gets one line at notice level when the output cannot be
    ///   lowered; `logError` gets a line without user content when a restore
    ///   cannot be confirmed.
    /// - `now` stamps and ages the owed restores.
    /// - `records` keeps the standing duck's debt across a crash; nil keeps none.
    public init(volume: SystemVolume,
                steps: Int = 5, stepDelay: TimeInterval = 0.05,
                settleDelay: TimeInterval = 0.08,
                log: @escaping (String) -> Void = { _ in },
                logError: @escaping (String) -> Void = { _ in },
                now: @escaping () -> Date = Date.init,
                records: DuckRecordStore? = nil) {
        self.volume = volume
        self.records = records
        self.steps = steps
        self.stepDelay = stepDelay
        self.settleDelay = settleDelay
        self.log = log
        self.logError = logError
        self.now = now
    }

    /// A dictation (generation `generation`) started recording. Returns whether
    /// the sound is handled: true once the output was lowered, and also when
    /// there was nothing audible to lower (muted, level 0) or a duck already
    /// stands; false when an audible output could not be lowered (no default
    /// device, no software volume — HDMI, a USB DAC, a Multi-Output device —
    /// an unreadable level, or a device that refused a write of the fade), so
    /// the caller can pause the players instead. A refused first write leaves
    /// no duck, record or owed restore behind, and the record is saved only
    /// once that write was accepted. A fade that stops after the first write
    /// also returns false, but the duck stands: the level is already lower
    /// and `end` restores it.
    @discardableResult
    public func begin(generation: Int) -> Bool {
        guard duck == nil else { return true }
        guard let device = volume.defaultDevice() else { return false }
        guard !volume.isMuted(device.id) else { return true }
        guard volume.isSettable(device.id) else {
            if !unsettableLogged {
                unsettableLogged = true
                log("output device has no settable volume: Lower All Sound falls back to Pause Music")
            }
            return false
        }
        guard let level = volume.volume(device.id) else { return false }
        guard level > 0 else { return true }
        let earlierOwed = device.uid.flatMap { owed[$0] }
        let preDuck = owedPreDuck(device: device, level: level)
        let duck = Duck(generation: generation, deviceID: device.id, uid: device.uid,
                        preDuck: preDuck, ducked: preDuck * Self.duckFraction)
        self.duck = duck
        let result = fade(from: level, to: duck.ducked, on: device.id) {
            if let uid = device.uid {
                self.records?.save(DuckRecord(uid: uid, preDuck: duck.preDuck, ducked: duck.ducked,
                                              savedAt: self.now()))
            }
        }
        switch result {
        case .complete:
            return true
        case .refusedFirst:
            // Nothing was lowered and the store was never touched: only the
            // owed restore this begin consumed goes back.
            self.duck = nil
            if let uid = device.uid { owed[uid] = earlierOwed }
            logError("output volume duck refused: the device did not take the first write")
            return false
        case .stopped:
            logError("output volume duck incomplete: the device stopped taking writes")
            return false
        }
    }

    /// At launch: a record left by a process that died while ducked. If the
    /// default output is that device, the record is younger than
    /// `recordLifetime` and it still sits about at the ducked level,
    /// the pre-duck level is given back; if the user has moved it since (or
    /// the device is no longer the default output) the record is dropped and
    /// the level left alone. An unconfirmed restore keeps the record for the
    /// next launch.
    public func recoverInterrupted() {
        guard duck == nil, let record = records?.load() else { return }
        // An older record, one without a timestamp and one dated further in
        // the future than a clock step explains are dropped without a write.
        guard let savedAt = record.savedAt,
              (-Self.clockSkewTolerance..<Self.recordLifetime).contains(now().timeIntervalSince(savedAt)) else {
            records?.clear()
            logError("output volume record dropped: too old, undated or dated in the future")
            return
        }
        guard let device = volume.defaultDevice(), device.uid == record.uid,
              let level = volume.volume(device.id),
              abs(level - record.ducked) <= Self.confirmTolerance else {
            records?.clear()
            return
        }
        if fade(from: level, to: record.preDuck, on: device.id) == .complete,
           confirmed(record.preDuck, on: device.id) {
            records?.clear()
        } else {
            logError("output volume recovery unconfirmed: level did not read back")
        }
    }

    /// The dictation of `generation` ended: the level it took is given back.
    public func end(generation: Int) {
        guard let duck, duck.generation == generation else { return }
        self.duck = nil
        restore(duck)
    }

    private enum Fade {
        case complete
        /// The device refused the first write: the level never moved.
        case refusedFirst
        /// A later write was refused: the level sits somewhere on the way.
        case stopped
    }

    /// The few-step ramp; stops early when the device stops taking writes,
    /// and says how far it got. `afterFirstWrite` runs once the first write
    /// was accepted.
    private func fade(from: Float, to: Float, on deviceID: UInt32,
                      afterFirstWrite: () -> Void = {}) -> Fade {
        for step in 1...max(1, steps) {
            if step > 1 && stepDelay > 0 { Thread.sleep(forTimeInterval: stepDelay) }
            let level = from + (to - from) * Float(step) / Float(max(1, steps))
            guard volume.setVolume(deviceID, level) else { return step == 1 ? .refusedFirst : .stopped }
            if step == 1 { afterFirstWrite() }
        }
        return .complete
    }

    /// Who the level is restored on: the device the duck captured, re-found
    /// by its persistent UID when a replug handed it a new AudioObjectID.
    /// The restore stays owed (in memory, by UID) while a device is away or
    /// a write was refused or never read back, and is forgotten the moment
    /// the level is back or `owedLifetime` has passed. A write the server refused never counts as landed,
    /// whatever the read says: at a tiny pre-duck level the still-ducked
    /// level sits inside `confirmTolerance` of the target.
    private func restore(_ duck: Duck) {
        let owedBack = Owed(preDuck: duck.preDuck, ducked: duck.ducked, since: now())
        let deviceID: UInt32
        if volume.volume(duck.deviceID) != nil {
            deviceID = duck.deviceID
        } else if let uid = duck.uid, let found = volume.device(forUID: uid) {
            deviceID = found
        } else {
            keepOwed(owedBack, for: duck.uid)
            logError("output volume restore deferred: the device is gone")
            return
        }
        guard let current = volume.volume(deviceID) else {
            keepOwed(owedBack, for: duck.uid)
            logError("output volume restore deferred: the volume cannot be read")
            return
        }
        if fade(from: current, to: duck.preDuck, on: deviceID) == .complete,
           confirmed(duck.preDuck, on: deviceID) {
            forgetOwed(for: duck.uid)
            return
        }
        if volume.setVolume(deviceID, duck.preDuck), confirmed(duck.preDuck, on: deviceID) {
            forgetOwed(for: duck.uid)
        } else {
            keepOwed(owedBack, for: duck.uid)
            logError("output volume restore unconfirmed: level did not read back")
        }
    }

    private func keepOwed(_ entry: Owed, for uid: String?) {
        if let uid { owed[uid] = entry }
    }

    private func forgetOwed(for uid: String?) {
        forgetRecord(for: uid)
        if let uid { owed[uid] = nil }
    }

    /// The store holds one record: it is cleared only when it is this
    /// device's, never another device's debt.
    private func forgetRecord(for uid: String?) {
        guard let uid, records?.load()?.uid == uid else { return }
        records?.clear()
    }

    /// A restore counts as landed once a settled read sits within
    /// `confirmTolerance` of the target — never a value-equality ask, so a
    /// quantizing output's snap counts. Each read is preceded by a settle
    /// and taken again a few times, because an asynchronous output can keep
    /// answering the pre-write level for the first reads.
    private func confirmed(_ target: Float, on deviceID: UInt32) -> Bool {
        for _ in 0..<Self.confirmReads {
            if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
            guard let read = volume.volume(deviceID) else { return false }
            if abs(read - target) <= Self.confirmTolerance { return true }
        }
        return false
    }

    /// The level a new duck owes back: normally the level just read — but
    /// when this device's last restore never landed and the output still sits
    /// where that duck left it, what is owed is the earlier pre-duck, not the
    /// quiet level a failed restore left behind. A level clearly above the
    /// ducked one means the user moved it since, and so does an entry older
    /// than `owedLifetime`: the entry is dropped and the level read is theirs.
    /// Entries of other devices are never touched.
    private func owedPreDuck(device: (id: UInt32, uid: String?), level: Float) -> Float {
        guard let uid = device.uid, let entry = owed.removeValue(forKey: uid) else { return level }
        guard now().timeIntervalSince(entry.since) < Self.owedLifetime else { return level }
        guard level <= Self.stillQuietBound(entry.ducked) else { return level }
        return entry.preDuck
    }

    /// The highest level that still counts as "as quiet as the duck left it":
    /// a fixed share above the ducked level, so a user who raised a quiet
    /// output by a little is not mistaken for it — or, for a ducked level so
    /// small that the share is less than a grid snap, the ducked level plus
    /// the snap's worst error (half a step) and the read slack. With pre 0.8
    /// (ducked 0.12) the bound is 0.18, not the 0.1925 of a fixed margin.
    private static func stillQuietBound(_ ducked: Float) -> Float {
        max(ducked * 1.5, ducked + quantizationStep / 2 + readSlack)
    }
}
