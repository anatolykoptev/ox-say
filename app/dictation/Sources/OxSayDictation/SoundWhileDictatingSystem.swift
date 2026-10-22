import AppKit
import DictationCore
import os

/// The macOS side of "Sound While Dictating": the real process list and
/// NSAppleScript for the players, and the CoreAudio output volume for the
/// duck, behind DictationCore's `SoundWhileDictatingWiring`. Browser media is
/// not covered by the pause — macOS limits MediaRemote to Apple's own apps
/// since 15.4; the duck covers everything the device plays.
enum SoundWhileDictatingSystem {
    /// Whether a bundle id is running now. Asked from the process list, never
    /// by an Apple Event: addressing a player that is not running would launch it.
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `onPermissionDenied` fires on a background queue, at most once per launch.
    static func makeRunner(onPermissionDenied: @escaping () -> Void) -> SoundWhileDictatingRunner {
        // Notice level so the unified log keeps it; lines carry a bundle id
        // and an error code, never user content.
        let logger = Logger(subsystem: "io.github.anatolykoptev.ox-say.dictation", category: "media")
        return SoundWhileDictatingWiring.makeRunner(
            isRunning: isRunning,
            volume: CoreAudioSystemVolume(),
            defaults: .standard,
            onPermissionDenied: onPermissionDenied,
            log: { logger.notice("\($0, privacy: .public)") },
            logError: { logger.error("\($0, privacy: .public)") })
    }
}
