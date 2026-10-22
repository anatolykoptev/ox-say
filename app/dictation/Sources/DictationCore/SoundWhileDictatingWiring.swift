import Foundation

/// Builds the "Sound While Dictating" machinery: the players with one
/// AppleScript worker each for "Pause Music", the output-volume duck for
/// "Lower All Sound", the menu setting that picks between them, and the
/// Automation-denied callback. It lives here, not in the app target, so a
/// test can run all of it with the process list, the scripts and the volume
/// replaced.
public enum SoundWhileDictatingWiring {
    public static let bundleIDs = [ScriptedMediaPlayer.musicBundleID, ScriptedMediaPlayer.spotifyBundleID]

    /// - `isRunning`: the system's process list for a bundle id (no Apple Event).
    /// - `execute`: runs one AppleScript source; each player gets its own worker.
    /// - `volume`: the system output volume the duck drives; nil leaves
    ///   "Lower All Sound" a no-op.
    /// - `defaults`: where the menu setting is read at every dictation.
    /// - `onPermissionDenied`: fires on a background queue, at most once.
    /// - `log` / `logError`: lines without user content.
    public static func makeRunner(
        isRunning: @escaping (String) -> Bool,
        execute: @escaping (String) -> ScriptOutcome = QueuedScriptRunner.executeWithNSAppleScript,
        volume: SystemVolume? = nil,
        defaults: UserDefaults,
        onPermissionDenied: @escaping () -> Void,
        log: @escaping (String) -> Void = { _ in },
        logError: @escaping (String) -> Void = { _ in }
    ) -> SoundWhileDictatingRunner {
        let players = bundleIDs.map { bundleID in
            ScriptedMediaPlayer(bundleID: bundleID, isRunning: isRunning,
                                runner: QueuedScriptRunner(label: bundleID, execute: execute), log: log)
        }
        // The runner's mode is the gate: `begin` runs only under "Pause Music".
        let pause = MediaPauseCoordinator(players: players, logError: logError)
        pause.onPermissionDenied = onPermissionDenied
        let duck = volume.map {
            VolumeDuckCoordinator(volume: $0, log: log, logError: logError)
        }
        return SoundWhileDictatingRunner(pause: pause, duck: duck,
                                         mode: { SoundWhileDictatingSetting.mode(defaults) })
    }
}
