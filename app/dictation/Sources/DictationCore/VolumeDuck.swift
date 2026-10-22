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
/// of its level; on every ending it fades back to exactly the level it had —
/// unless the user touched the volume meanwhile (the read-back then differs
/// from what the duck wrote) or the device went away. A marker persisted
/// while ducked lets the next launch finish a restore a crash skipped.
///
/// Not thread safe: `SoundWhileDictatingRunner` feeds it from one serial
/// queue, where `begin` and `end` alternate per generation.
public final class VolumeDuckCoordinator {
    /// The ducked level is this fraction of the level at the key down.
    public static let duckFraction: Float = 0.15
    /// How far a read-back may drift from a written level and still count as
    /// ours — small enough that one press of a volume key (1/16) exceeds it.
    public static let tolerance: Float = 0.02
    /// The defaults key of the persisted duck: device UID, pre-duck and
    /// ducked levels, present only while a duck may still be owed.
    public static let markerKey = "soundDuckRestore"

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
    private let log: (String) -> Void
    private let logError: (String) -> Void
    private var duck: Duck?
    /// One log line per launch for outputs without a settable volume.
    private var unsettableLogged = false

    /// - `steps`/`stepDelay` shape the fade: 5 steps of 50 ms ≈ 250 ms.
    /// - `log` gets one line at notice level when the output cannot be lowered
    ///   or was taken over; `logError` gets a line without user content when a
    ///   restore cannot be confirmed.
    public init(volume: SystemVolume, defaults: UserDefaults,
                steps: Int = 5, stepDelay: TimeInterval = 0.05,
                log: @escaping (String) -> Void = { _ in },
                logError: @escaping (String) -> Void = { _ in }) {
        self.volume = volume
        self.defaults = defaults
        self.steps = steps
        self.stepDelay = stepDelay
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
        let duck = Duck(generation: generation, deviceID: device.id, uid: device.uid,
                        preDuck: level, ducked: level * Self.duckFraction)
        self.duck = duck
        writeMarker(duck)
        fade(from: level, to: duck.ducked, on: device.id)
    }

    /// The dictation of `generation` ended: gives the level back unless the
    /// user took the volume over meanwhile, then nothing is owed.
    public func end(generation: Int) {
        guard let duck, duck.generation == generation else { return }
        self.duck = nil
        restore(duck)
    }

    /// The launch pass over the crash marker: the marker is always consumed;
    /// the level it names is restored only when the device is still around
    /// and still sits where the dead process left it.
    public func restoreInterruptedDuck() {
        guard let marker = defaults.dictionary(forKey: Self.markerKey) else { return }
        defaults.removeObject(forKey: Self.markerKey)
        guard let uid = marker["uid"] as? String,
              let pre = marker["pre"] as? Double, let ducked = marker["ducked"] as? Double,
              let deviceID = volume.device(forUID: uid),
              let current = volume.volume(deviceID),
              abs(current - Float(ducked)) <= Self.tolerance else { return }
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
    /// The marker stays while a restore is still owed — a device that went
    /// away or a write the server never confirmed — and is cleared the moment
    /// nothing is: the level is back, or it is the user's now.
    private func restore(_ duck: Duck) {
        let deviceID: UInt32
        if volume.volume(duck.deviceID) != nil {
            deviceID = duck.deviceID
        } else if let uid = duck.uid, let found = volume.device(forUID: uid) {
            deviceID = found
        } else { return }
        guard let current = volume.volume(deviceID) else { return }
        guard abs(current - duck.ducked) <= Self.tolerance else {
            defaults.removeObject(forKey: Self.markerKey)
            log("the volume was changed during the dictation: left at the user's level")
            return
        }
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

    private func confirmed(_ target: Float, on deviceID: UInt32) -> Bool {
        guard let read = volume.volume(deviceID) else { return false }
        return abs(read - target) <= Self.tolerance
    }

    /// The crash marker names the device by UID — an AudioObjectID does not
    /// survive re-enumeration — and both levels, so the launch pass can tell
    /// "still ducked" from "the user moved it while we were dead".
    private func writeMarker(_ duck: Duck) {
        guard let uid = duck.uid else { return }
        defaults.set(["uid": uid, "pre": Double(duck.preDuck), "ducked": Double(duck.ducked)],
                     forKey: Self.markerKey)
    }
}
