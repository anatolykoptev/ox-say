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
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac",
    ]

    /// The app's own bundle: dictation holds the microphone too and is never a call.
    public static let ownBundleID = "io.github.anatolykoptev.ox-say.dictation"

    /// A browser's audio comes from a helper process ("com.google.Chrome.helper…"):
    /// the helper's name without its suffix is the browser.
    public static func canonical(_ bundleID: String) -> String {
        if let r = bundleID.range(of: ".helper") { return String(bundleID[..<r.lowerBound]) }
        return bundleID
    }

    /// Sources that start a recording by themselves. Discord holds the
    /// microphone all day in a voice channel and FaceTime is usually a personal
    /// call: for those the badge asks first, whatever the auto-start setting says.
    public static let autoStartSources: Set<String> = ["zoom", "teams", "webex", "meet"]

    /// The call among the microphone users, or nil: its source name and the
    /// (canonical) bundle id that holds the microphone. `activeURL` returns the
    /// address of a browser's front tab; it is asked only for a browser that
    /// holds the microphone.
    public static func match(of users: [MicUser], activeURL: (String) -> String?) -> (source: String, bundleID: String)? {
        for user in users {
            let id = canonical(user.bundleID)
            if id == ownBundleID { continue }
            if let native = nativeApps[id] { return (native, id) }
            if browsers.contains(id), let url = activeURL(id), let web = MeetingURL.source(of: url) { return (web, id) }
        }
        return nil
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
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/wc/") || path.hasPrefix("/j/") ? "zoom" : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.contains("/meet") || path.contains("meetup-join") ? "teams" : nil
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
    public static let endAfter: TimeInterval = 30

    private var callSince: Date?
    private var quietSince: Date?
    private var idleSince: Date?
    private var announced = false
    private var declined = false

    public init() {}

    /// Forget the current call: the user said "don't record this one". The
    /// call is not offered again until it has ended.
    public mutating func decline() { declined = true }

    /// One observation. `call` is the detected source or nil; `themActive` is
    /// whether the other side was audible lately; `recording` is nil when idle,
    /// else how the recording began (only an auto-started one is stopped here).
    public mutating func observe(now: Date, call: String?, themActive: Bool, recording: Origin?) -> Action {
        if let call {
            quietSince = nil
            idleSince = nil
            if callSince == nil { callSince = now }
            if recording == nil, !announced, !declined, now.timeIntervalSince(callSince!) >= Self.startAfter {
                announced = true
                return .callStarted(source: call)
            }
            return .nothing
        }
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
            }
        }
        return .nothing
    }
}
