import Foundation

/// A process that has the microphone open right now.
public struct MicUser: Equatable {
    public var bundleID: String
    public var pid: Int32

    public init(bundleID: String, pid: Int32) {
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// Tells a call from any other use of the microphone. Allowlist-based: an app
/// that is not named here — a dictation tool, a voice memo — never starts a recording.
public enum CallDetector {
    /// Native call apps by bundle id → the source name stored with the meeting.
    public static let nativeApps: [String: String] = [
        "us.zoom.xos": "zoom",
        "com.microsoft.teams2": "teams",
        "com.microsoft.teams": "teams",
        "com.tinyspeck.slackmacgap": "slack",
        "com.apple.FaceTime": "facetime",
        "com.cisco.webexmeetingsapp": "webex",
        "com.hnc.Discord": "discord",
    ]

    /// Browsers whose active tab the app can read by Apple Events. Safari is not
    /// here: its web content audio is attributed to com.apple.WebKit.* helpers,
    /// which cannot be tied to the tab.
    /// Known limits: Firefox and installed web apps (PWAs) are not read; only the
    /// front window's active tab is; and a Meet lobby holds the microphone while its
    /// URL is the same as the call's, so it counts as a call.
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac",
    ]

    /// The app's own bundle: dictation holds the microphone too and is never a call.
    public static let ownBundleID = "io.github.anatolykoptev.ox-say.dictation"

    /// A browser's audio comes from a helper process ("com.google.Chrome.helper.Renderer"):
    /// the id up to its `helper` component is the browser. Only a whole `.helper`
    /// component counts, so "com.acme.helperapp" stays itself.
    public static func canonical(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(of: "helper"), i > 0 else { return bundleID }
        return parts[..<i].joined(separator: ".")
    }

    /// Sources that start a recording by themselves. Discord holds the
    /// microphone all day in a voice channel and FaceTime is usually a personal
    /// call: for those the badge asks first, whatever the auto-start setting says.
    public static let autoStartSources: Set<String> = ["zoom", "teams", "webex", "meet"]

    /// What the microphone users add up to.
    public struct Detection: Equatable {
        public struct Call: Equatable {
            public var source: String
            public var bundleID: String
        }

        public var call: Call?
        /// Only meaningful when `call` is nil. A browser holds the microphone and
        /// Automation for it is off: a Meet call there looks exactly like no call,
        /// so the app must say so instead of staying silent.
        public var browserDenied = false
        /// Only meaningful when `call` is nil. A browser holds the microphone but
        /// its tab could not be read this time (timeout, no window); `CallTracker`
        /// tolerates one such tick.
        public var browserUnreadable = false
    }

    /// The call among the microphone users. A browser is asked for its front tab
    /// (once) only when it holds the microphone. When several calls are live, one
    /// that starts a recording by itself wins over one that only asks, then the
    /// lowest bundle id: the answer does not depend on the order of the process list.
    public static func detect(of users: [MicUser], tab: (String) -> BrowserTabURL.Result) -> Detection {
        var found: [Detection.Call] = []
        var asked: [String: BrowserTabURL.Result] = [:]
        var denied = false
        var unreadable = false
        for user in users {
            let id = canonical(user.bundleID)
            if id == ownBundleID { continue }
            if let native = nativeApps[id] {
                found.append(.init(source: native, bundleID: id))
            } else if browsers.contains(id) {
                let result = asked[id] ?? tab(id)
                asked[id] = result
                switch result {
                case .url(let address):
                    if let web = MeetingURL.source(of: address) { found.append(.init(source: web, bundleID: id)) }
                case .denied: denied = true
                case .unreadable: unreadable = true
                }
            }
        }
        let best = found.min { l, r in
            let lAuto = autoStartSources.contains(l.source), rAuto = autoStartSources.contains(r.source)
            if lAuto != rAuto { return lAuto }
            if l.bundleID != r.bundleID { return l.bundleID < r.bundleID }
            return l.source < r.source
        }
        return Detection(call: best, browserDenied: best == nil && denied, browserUnreadable: best == nil && unreadable)
    }

    /// The call among the microphone users, or nil: its source name and the
    /// (canonical) bundle id that holds the microphone. `activeURL` returns the
    /// address of a browser's front tab, nil when unreadable.
    public static func match(of users: [MicUser], activeURL: (String) -> String?) -> (source: String, bundleID: String)? {
        let call = detect(of: users, tab: { activeURL($0).map(BrowserTabURL.Result.url) ?? .unreadable }).call
        return call.map { ($0.source, $0.bundleID) }
    }

    /// The call source among the microphone users, or nil.
    public static func source(of users: [MicUser], activeURL: (String) -> String?) -> String? {
        match(of: users, activeURL: activeURL)?.source
    }

    /// Whether `bundleID` (canonical) still has the microphone. A browser call
    /// continues while its browser holds the microphone, whichever tab is in front.
    public static func holds(_ users: [MicUser], bundleID: String) -> Bool {
        users.contains { canonical($0.bundleID) == bundleID }
    }
}

/// Recognizes a meeting page by its address.
public enum MeetingURL {
    public static func source(of address: String) -> String? {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "meet.google.com" {
            // a room code like abc-defg-hij; /landing and the lobby home are not a call
            return path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}", options: .regularExpression) != nil ? "meet" : nil
        }
        for zoom in ["zoom.us", "zoomgov.com"] where host == zoom || host.hasSuffix("." + zoom) {
            return path.hasPrefix("/wc/") || path.hasPrefix("/j/") ? "zoom" : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            // The classic link keeps its route in the fragment ("/_#/l/meetup-join/…").
            let fragment = url.fragment.map { $0.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "" } ?? ""
            for route in [path, fragment] where route.contains("/l/meetup-join/") || route.hasPrefix("/meet/") {
                return "teams"
            }
        }
        return nil
    }
}

/// Turns the stream of "is a call going on" observations into the three things
/// the app does: offer or start a recording, and stop one it started itself.
/// Debounced both ways — a mute releases the browser's microphone for a while,
/// and a call that is only muted still plays the other side's voice.
public struct CallTracker {
    public enum Origin: Equatable { case manual, auto }

    public enum Action: Equatable {
        case nothing
        /// A call has held the microphone for `startAfter`: record it (auto-start) or ask.
        case callStarted(source: String)
        /// The call is over: no call app on the microphone and the other side silent for `endAfter`.
        case stopRecording
    }

    public static let startAfter: TimeInterval = 4
    /// Mutual silence that ends an auto-started recording. Group calls go quiet for
    /// long stretches (a document review, a silent screen share), and a silent tail
    /// transcribes to nothing, so this errs long.
    public static let endAfter: TimeInterval = 90

    private var callSince: Date?
    private var quietSince: Date?
    private var idleSince: Date?
    private var announced = false
    private var declined = false
    /// Which app/page the current call episode belongs to; a different one is a new call.
    private var episode: String?
    /// Consecutive ticks on which a browser held the microphone but its tab was unreadable.
    private var unreadableTicks = 0

    public init() {}

    /// Forget the current call: the user said "don't record this one". The
    /// call is not offered again until it has ended.
    public mutating func decline() { declined = true }

    /// One observation. `call` is the detected source or nil; `bundleID` is the app
    /// that holds it (a change of source or app starts a new call episode);
    /// `themActive` is whether the other side was audible lately; `recording` is
    /// nil when idle, else how the recording began (only an auto-started one is
    /// stopped here); `callUnreadable` says a browser held the microphone but its
    /// tab could not be read — one such tick does not break the debounce.
    public mutating func observe(now: Date, call: String?, themActive: Bool, recording: Origin?,
                                 bundleID: String? = nil, callUnreadable: Bool = false) -> Action {
        if let call {
            unreadableTicks = 0
            quietSince = nil
            idleSince = nil
            let key = call + "|" + (bundleID ?? "")
            if let episode, episode != key {
                announced = false
                declined = false
                callSince = nil
            }
            episode = key
            if callSince == nil { callSince = now }
            if recording != nil {
                // A recording is already running (the user started it, or we did): this
                // call is taken care of. When it stops while the call goes on, a user's
                // stop stays stopped; only an automatic stop re-arms (below).
                announced = true
                return .nothing
            }
            if !announced, !declined, now.timeIntervalSince(callSince!) >= Self.startAfter {
                announced = true
                return .callStarted(source: call)
            }
            return .nothing
        }
        if callUnreadable, callSince != nil, unreadableTicks < 1 {
            unreadableTicks += 1
            return .nothing
        }
        unreadableTicks = 0
        callSince = nil
        switch recording {
        case .auto:
            idleSince = nil
            if themActive {
                quietSince = nil
            } else {
                if quietSince == nil { quietSince = now }
                if now.timeIntervalSince(quietSince!) >= Self.endAfter {
                    quietSince = nil
                    // The call may well go on (a muted listener, a long silence): offer it again.
                    announced = false
                    return .stopRecording
                }
            }
        case .manual:
            quietSince = nil
            idleSince = nil
        case nil:
            // No call, no recording: after endAfter the call episode is over and the next one is new.
            quietSince = nil
            if idleSince == nil { idleSince = now }
            if now.timeIntervalSince(idleSince!) >= Self.endAfter {
                announced = false
                declined = false
                episode = nil
            }
        }
        return .nothing
    }
}
