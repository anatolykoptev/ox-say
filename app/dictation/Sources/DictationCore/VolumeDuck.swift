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

/// "Lower All Sound": on the key down the default output fades to a fraction
/// of its level; on every ending it fades back to exactly the level it had.
/// Restore wins: a level the user picked during the few seconds of a
/// dictation loses to the restore, because an output left quiet forever is
/// the larger harm — and no comparison of levels can tell every device's
/// duck from a user change. A restore that could not be confirmed stays owed
/// in memory, per device, and is applied by the next dictation on that device
/// if the output is still as quiet as the duck left it. Nothing is persisted:
/// a process that dies mid-dictation leaves the output quiet until the user
/// raises it.
///
/// Not thread safe: `SoundWhileDictatingRunner` feeds it from one serial
/// queue, where `begin` and `end` alternate per generation.
public final class VolumeDuckCoordinator {
    /// The ducked level is this fraction of the level at the key down.
    public static let duckFraction: Float = 0.15
    /// How far a settled read may sit from the level it was asked to hold
    /// and still count as restored — generous enough for an output that
    /// snaps every write to a 1/16 grid (the volume keys' step) to land
    /// inside it from any computed target.
    public static let confirmTolerance: Float = 1.0 / 16 + 0.01
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

    /// A restore that did not land: the level the device is owed and the
    /// level the duck left it at.
    private struct Owed {
        let preDuck: Float
        let ducked: Float
    }

    private let volume: SystemVolume
    private let steps: Int
    private let stepDelay: TimeInterval
    private let settleDelay: TimeInterval
    private let log: (String) -> Void
    private let logError: (String) -> Void
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
    public init(volume: SystemVolume,
                steps: Int = 5, stepDelay: TimeInterval = 0.05,
                settleDelay: TimeInterval = 0.08,
                log: @escaping (String) -> Void = { _ in },
                logError: @escaping (String) -> Void = { _ in }) {
        self.volume = volume
        self.steps = steps
        self.stepDelay = stepDelay
        self.settleDelay = settleDelay
        self.log = log
        self.logError = logError
    }

    /// A dictation (generation `generation`) started recording. Nothing is
    /// ducked when the output is muted, silent, or has no software volume,
    /// and a duck already standing is never re-ducked.
    public func begin(generation: Int) {
        guard duck == nil, let device = volume.defaultDevice(),
              !volume.isMuted(device.id) else { return }
        guard volume.isSettable(device.id) else {
            if !unsettableLogged {
                unsettableLogged = true
                log("output device has no settable volume: Lower All Sound does nothing")
            }
            return
        }
        guard let level = volume.volume(device.id), level > 0 else { return }
        let preDuck = owedPreDuck(device: device, level: level)
        let duck = Duck(generation: generation, deviceID: device.id, uid: device.uid,
                        preDuck: preDuck, ducked: preDuck * Self.duckFraction)
        self.duck = duck
        fade(from: level, to: duck.ducked, on: device.id)
    }

    /// The dictation of `generation` ended: the level it took is given back.
    public func end(generation: Int) {
        guard let duck, duck.generation == generation else { return }
        self.duck = nil
        restore(duck)
    }

    /// The few-step ramp; stops early when the device stops taking writes,
    /// and says whether every write was accepted.
    @discardableResult
    private func fade(from: Float, to: Float, on deviceID: UInt32) -> Bool {
        for step in 1...max(1, steps) {
            if step > 1 && stepDelay > 0 { Thread.sleep(forTimeInterval: stepDelay) }
            let level = from + (to - from) * Float(step) / Float(max(1, steps))
            guard volume.setVolume(deviceID, level) else { return false }
        }
        return true
    }

    /// Who the level is restored on: the device the duck captured, re-found
    /// by its persistent UID when a replug handed it a new AudioObjectID.
    /// The restore stays owed (in memory, by UID) while a device is away or
    /// a write was refused or never read back, and is forgotten the moment
    /// the level is back. A write the server refused never counts as landed,
    /// whatever the read says: at a tiny pre-duck level the still-ducked
    /// level sits inside `confirmTolerance` of the target.
    private func restore(_ duck: Duck) {
        let owedBack = Owed(preDuck: duck.preDuck, ducked: duck.ducked)
        let deviceID: UInt32
        if volume.volume(duck.deviceID) != nil {
            deviceID = duck.deviceID
        } else if let uid = duck.uid, let found = volume.device(forUID: uid) {
            deviceID = found
        } else {
            keepOwed(owedBack, for: duck.uid)
            return
        }
        guard let current = volume.volume(deviceID) else {
            keepOwed(owedBack, for: duck.uid)
            return
        }
        if fade(from: current, to: duck.preDuck, on: deviceID),
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
        if let uid { owed[uid] = nil }
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
    /// ducked one means the user moved it since: the entry is dropped and the
    /// level read is theirs. Entries of other devices are never touched.
    private func owedPreDuck(device: (id: UInt32, uid: String?), level: Float) -> Float {
        guard let uid = device.uid, let entry = owed.removeValue(forKey: uid) else { return level }
        guard level <= entry.ducked + Self.confirmTolerance else { return level }
        return entry.preDuck
    }
}
