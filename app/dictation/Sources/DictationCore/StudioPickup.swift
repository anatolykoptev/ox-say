import Foundation

/// The launch pickup of a voiceover that is already running (the app quit and came back, or began before the daemon
/// was up). The decision is here so a test can see it; the follower does the looking.
public enum StudioPickup {
    /// Whether a /status result should make the follower look for a running voiceover: any ANSWER does, even one that
    /// says the studio is unavailable (the daemon is up, its recent voiceovers can be read); no answer does not.
    public static func lookOnStatus(_ status: DaemonStatus?) -> Bool { status != nil }
}
