import AppKit
import DictationCore
import os

/// The macOS side of "Pause Music While Dictating": the real process list and
/// NSAppleScript behind DictationCore's coordinator. Browser media is not
/// covered — macOS limits MediaRemote to Apple's own apps since 15.4.
enum MediaPauseSystem {
    /// Whether a bundle id is running now. Asked from the process list, never
    /// by an Apple Event: addressing a player that is not running would launch it.
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `onPermissionDenied` fires on a background queue, at most once per launch.
    static func makeRunner(onPermissionDenied: @escaping () -> Void) -> MediaPauseRunner {
        // Notice level so the unified log keeps it; lines carry a bundle id and
        // an error code, never user content.
        let logger = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "media")
        let scripts = QueuedScriptRunner()
        let players = [ScriptedMediaPlayer.musicBundleID, ScriptedMediaPlayer.spotifyBundleID].map {
            ScriptedMediaPlayer(bundleID: $0, isRunning: isRunning, runner: scripts,
                                log: { logger.notice("\($0, privacy: .public)") })
        }
        let coordinator = MediaPauseCoordinator(players: players,
                                                isEnabled: { MediaPauseSetting.isEnabled(.standard) })
        coordinator.onPermissionDenied = onPermissionDenied
        return MediaPauseRunner(coordinator: coordinator)
    }
}
