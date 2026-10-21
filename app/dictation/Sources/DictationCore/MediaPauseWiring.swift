import Foundation

/// Builds the "Pause Music While Dictating" machinery: which players, one
/// AppleScript worker each, the menu setting, the Automation-denied callback.
/// It lives here, not in the app target, so a test can run all of it with the
/// process list and the scripts replaced.
public enum MediaPauseWiring {
    public static let bundleIDs = [ScriptedMediaPlayer.musicBundleID, ScriptedMediaPlayer.spotifyBundleID]

    /// - `isRunning`: the system's process list for a bundle id (no Apple Event).
    /// - `execute`: runs one AppleScript source; each player gets its own worker.
    /// - `defaults`: where the menu setting is read at every dictation.
    /// - `onPermissionDenied`: fires on a background queue, at most once.
    /// - `log` / `logError`: lines without user content.
    public static func makeRunner(
        isRunning: @escaping (String) -> Bool,
        execute: @escaping (String) -> ScriptOutcome = QueuedScriptRunner.executeWithNSAppleScript,
        defaults: UserDefaults,
        onPermissionDenied: @escaping () -> Void,
        log: @escaping (String) -> Void = { _ in },
        logError: @escaping (String) -> Void = { _ in }
    ) -> MediaPauseRunner {
        let players = bundleIDs.map { bundleID in
            ScriptedMediaPlayer(bundleID: bundleID, isRunning: isRunning,
                                runner: QueuedScriptRunner(label: bundleID, execute: execute), log: log)
        }
        let coordinator = MediaPauseCoordinator(players: players,
                                                isEnabled: { MediaPauseSetting.isEnabled(defaults) },
                                                logError: logError)
        coordinator.onPermissionDenied = onPermissionDenied
        return MediaPauseRunner(coordinator: coordinator)
    }
}
