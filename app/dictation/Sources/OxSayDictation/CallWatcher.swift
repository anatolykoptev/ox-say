import DictationCore
import Foundation

/// Polls CoreAudio for the processes that have a microphone open, every two
/// seconds, and feeds them to a CallWatch — detection, the debounce and the
/// "call goes on while its browser holds the mic" rule (#241) live there, not
/// here. The poll is a handful of property reads; while a browser holds the
/// microphone its tab is read by AppleScript on a background queue, one read at
/// a time per browser, and the poll uses the last completed result — the main
/// thread (badge Stop, hotkeys) never waits for a browser.
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
        /// Set once: a browser holds the microphone and its tab has not been readable for several polls — an
        /// Automation prompt nobody answered (#251). The app shows notice.meeting.browser_pending.
        var browserNeedsPermission: Bool
    }

    var onTick: ((Tick) -> Void)?
    /// What the tracker cannot see: how a running recording began (nil = idle)
    /// and whether the other side was audible lately. The recorder wires both.
    var recording: () -> CallTracker.Origin? = { nil }
    var themActive: () -> Bool = { false }
    /// The sources the user set to "Don't record": they never hide another call (#270).
    var ignoredSources: () -> Set<String> = { [] }

    private var watch = CallWatch()
    private var runners: [String: QueuedScriptRunner] = [:]
    private let tabReads = BrowserTabReads(queue: DispatchQueue(label: "io.github.anatolykoptev.ox-say.dictation.tabreads",
                                                                 qos: .utility, attributes: .concurrent))
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        // .common: the poll keeps running while a menu is open or a control is tracked.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Stops polling and forgets the call: a call seen before a stop is not
    /// the memory of a later one.
    func stop() {
        timer?.invalidate()
        timer = nil
        watch = CallWatch()
        tabReads.reset()
    }

    /// "Don't record this one": the current call is not offered again.
    func decline() { watch.decline() }

    private func tick() {
        let me = getpid()
        // A CoreAudio error is not "nobody has the microphone": skip the round.
        guard let processes = CoreAudioProps.audioProcesses() else { return }
        let users = processes
            .filter { $0.runningInput && $0.pid != me }
            .map { MicUser(bundleID: $0.bundleID, pid: $0.pid) }
        let outcome = watch.observe(now: Date(), users: users, tab: readTab,
                                  themActive: themActive(), recording: recording(),
                                  ignoring: ignoredSources())
        onTick?(Tick(users: users, call: outcome.call, action: outcome.action, browserDenied: outcome.browserDenied,
                     browserNeedsPermission: outcome.browserNeedsPermission))
    }

    /// Main thread: asks for a fresh read (a no-op while one is pending) and answers
    /// with the last completed one; before the first completes it is `.unreadable`,
    /// which the tracker tolerates for one round.
    private func readTab(_ bundleID: String) -> BrowserTabURL.Result {
        // dropWhileBusy: a read stuck behind an unanswered Automation prompt holds the worker; the next polls are
        // answered "unreadable" instead of piling scripts up behind it (#251).
        let runner = runners[bundleID] ?? QueuedScriptRunner(label: bundleID, dropWhileBusy: true)
        runners[bundleID] = runner
        tabReads.request(bundleID) { BrowserTabURL.read(bundleID: bundleID, runner: runner) }
        return tabReads.latest(bundleID) ?? .unreadable
    }
}
