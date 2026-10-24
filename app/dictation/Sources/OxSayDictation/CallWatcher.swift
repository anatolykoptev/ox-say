import DictationCore
import Foundation

/// Polls CoreAudio for the processes that have a microphone open, every two
/// seconds, and feeds them to a CallWatch — detection, the debounce and the
/// "call goes on while its browser holds the mic" rule (#241) live there, not
/// here. The poll is a handful of property reads and, only while a browser
/// holds the microphone, one bounded AppleScript tab read: it adds nothing
/// measurable to an idle app.
@available(macOS 14.2, *)
final class CallWatcher {
    /// One poll's outcome.
    struct Tick {
        /// Every process with input running, the app's own pid excluded.
        var users: [MicUser]
        /// The call that counts this round — a browser call still counts while
        /// its browser holds the microphone, whichever tab is in front.
        var call: CallDetector.Detection.Call?
        /// What the tracker made of the round: offer/start, stop, or nothing.
        var action: CallTracker.Action
        /// Set once: a browser held the microphone with Automation off. The app
        /// shows notice.meeting.browser_denied — otherwise it reads as no call.
        var browserDenied: Bool
    }

    var onTick: ((Tick) -> Void)?
    /// What the tracker cannot see: how a running recording began (nil = idle)
    /// and whether the other side was audible lately. The recorder wires both.
    var recording: () -> CallTracker.Origin? = { nil }
    var themActive: () -> Bool = { false }

    private var watch = CallWatch()
    private var runners: [String: QueuedScriptRunner] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// "Don't record this one": the current call is not offered again.
    func decline() { watch.decline() }

    private func tick() {
        let me = getpid()
        let users = CoreAudioProps.audioProcesses()
            .filter { $0.runningInput && $0.pid != me }
            .map { MicUser(bundleID: $0.bundleID, pid: $0.pid) }
        let outcome = watch.observe(now: Date(), users: users, tab: readTab,
                                  themActive: themActive(), recording: recording())
        onTick?(Tick(users: users, call: outcome.call, action: outcome.action, browserDenied: outcome.browserDenied))
    }

    private func readTab(_ bundleID: String) -> BrowserTabURL.Result {
        let runner = runners[bundleID] ?? QueuedScriptRunner(label: bundleID)
        runners[bundleID] = runner
        return BrowserTabURL.read(bundleID: bundleID, runner: runner)
    }
}
