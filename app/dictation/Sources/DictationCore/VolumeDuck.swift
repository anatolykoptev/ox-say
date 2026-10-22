import Foundation

/// What "Lower All Sound" talks to: the system output volume. Each call is a
/// brief synchronous trip to the audio server, so they all run on the
/// runner's serial queue.
public protocol SystemVolume: AnyObject {
    /// The default output device: its AudioObjectID and persistent UID (`nil`
    /// when the device exposes none — the crash marker cannot name it then).
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
    /// The AudioObjectID a persisted UID resolves to now; nil when the device
    /// is gone.
    func device(forUID uid: String) -> UInt32?
}

/// "Lower All Sound": on the key down the default output fades to a fraction
/// of its level; on every ending it fades back to exactly the level it had.
/// Restore wins: a level the user picked during the few seconds of a
/// dictation loses to the restore, because an output left quiet forever is
/// the larger harm — and no comparison of levels can tell every device's
/// duck from a user change. A marker persisted while ducked lets the next
/// launch finish a restore a crash skipped.
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
    /// The defaults key of the persisted duck: device UID, pre-duck and
    /// ducked levels, present only while a duck may still be owed.
    public static let markerKey = "soundDuckRestore"
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

    private let volume: SystemVolume
    private let defaults: UserDefaults
    private let steps: Int
    private let stepDelay: TimeInterval
    private let settleDelay: TimeInterval
    private let log: (String) -> Void
    private let logError: (String) -> Void
    private var duck: Duck?
    /// One log line per launch for outputs without a settable volume.
    private var unsettableLogged = false

    /// - `steps`/`stepDelay` shape the fade: 5 steps of 50 ms ≈ 250 ms.
    /// - `settleDelay` pauses before each confirm read, so an output that
    ///   applies volume asynchronously has landed the write first: 80 ms.
    /// - `log` gets one line at notice level when the output cannot be
    ///   lowered; `logError` gets a line without user content when a restore
    ///   cannot be confirmed.
    public init(volume: SystemVolume, defaults: UserDefaults,
                steps: Int = 5, stepDelay: TimeInterval = 0.05,
                settleDelay: TimeInterval = 0.08,
                log: @escaping (String) -> Void = { _ in },
                logError: @escaping (String) -> Void = { _ in }) {
        self.volume = volume
        self.defaults = defaults
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
        writeMarker(duck)
        fade(from: level, to: duck.ducked, on: device.id)
    }

    /// The dictation of `generation` ended: the level it took is given back.
    public func end(generation: Int) {
        guard let duck, duck.generation == generation else { return }
        self.duck = nil
        restore(duck)
    }

    /// The launch pass over the crash marker. A marker that cannot be read
    /// is cleared; one whose device is gone keeps standing for the launch
    /// that finds it back. Otherwise the level it names is given back —
    /// unless the output already sits clearly above the ducked level, which
    /// means someone raised it while the process was dead. The marker is
    /// always consumed once a device answers.
    public func restoreInterruptedDuck() {
        guard let marker = defaults.dictionary(forKey: Self.markerKey) else { return }
        guard let uid = marker["uid"] as? String,
              let pre = marker["pre"] as? Double, let ducked = marker["ducked"] as? Double
        else {
            defaults.removeObject(forKey: Self.markerKey)
            return
        }
        guard let deviceID = volume.device(forUID: uid) else { return }
        // A read right after launch can still show the pre-write level on
        // an output that applies volume asynchronously — read twice past a
        // settle and trust the later one.
        var current = volume.volume(deviceID)
        if settleDelay > 0 { Thread.sleep(forTimeInterval: settleDelay) }
        if let reread = volume.volume(deviceID) { current = reread }
        guard let current = current else { return }
        defaults.removeObject(forKey: Self.markerKey)
        guard current <= Float(ducked) + Self.confirmTolerance else { return }
        fade(from: current, to: Float(pre), on: deviceID)
    }

    /// The few-step ramp; stops early when the device stops taking writes.
    private func fade(from: Float, to: Float, on deviceID: UInt32) {
        for step in 1...max(1, steps) {
            if step > 1 && stepDelay > 0 { Thread.sleep(forTimeInterval: stepDelay) }
            let level = from + (to - from) * Float(step) / Float(max(1, steps))
            guard volume.setVolume(deviceID, level) else { return }
        }
    }

    /// Who the level is restored on: the device the duck captured, re-found
    /// by its persistent UID when a replug handed it a new AudioObjectID.
    /// The marker stands while a restore is still owed — a device that went
    /// away or a write the server never confirmed — and is cleared the
    /// moment the level is back.
    private func restore(_ duck: Duck) {
        let deviceID: UInt32
        if volume.volume(duck.deviceID) != nil {
            deviceID = duck.deviceID
        } else if let uid = duck.uid, let found = volume.device(forUID: uid) {
            deviceID = found
        } else { return }
        guard let current = volume.volume(deviceID) else { return }
        fade(from: current, to: duck.preDuck, on: deviceID)
        guard !confirmed(duck.preDuck, on: deviceID) else {
            defaults.removeObject(forKey: Self.markerKey)
            return
        }
        volume.setVolume(deviceID, duck.preDuck)
        if confirmed(duck.preDuck, on: deviceID) {
            defaults.removeObject(forKey: Self.markerKey)
        } else {
            logError("output volume restore unconfirmed: level did not read back")
        }
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
    /// while a marker for this device still stands a restore is owed, and
    /// what is owed is the marker's pre-duck, never the current level,
    /// which a restore that never landed may have left quiet.
    private func owedPreDuck(device: (id: UInt32, uid: String?), level: Float) -> Float {
        guard let uid = device.uid,
              let marker = defaults.dictionary(forKey: Self.markerKey),
              marker["uid"] as? String == uid,
              let pre = marker["pre"] as? Double
        else { return level }
        return Float(pre)
    }

    /// The crash marker names the device by UID — an AudioObjectID does not
    /// survive re-enumeration — the level owed back and the level the duck
    /// aimed for, so the launch pass can tell "still ducked" from "raised
    /// while we were dead". Keys a marker from another version adds are
    /// ignored.
    private func writeMarker(_ duck: Duck) {
        guard let uid = duck.uid else { return }
        defaults.set(["uid": uid, "pre": Double(duck.preDuck),
                      "ducked": Double(duck.ducked)], forKey: Self.markerKey)
    }
}
