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
        "net.whatsapp.WhatsApp": "whatsapp",
        // Telegram: the Mac App Store app, the Mac App Store "Telegram Lite", and the direct Telegram Desktop build.
        "ru.keepcoder.Telegram": "telegram",
        "org.telegram.desktop": "telegram",
        "com.tdesktop.Telegram": "telegram",
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
    public static let autoStartSources: Set<String> = ["zoom", "teams", "webex", "meet", "oxpulse"]

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
    /// `mode`: the user's pick per source (`CallPolicy.mode`). Holders are ordered by it — Record, then Ask, then
    /// "Don't record" last (#270) — so a source set to Record is not hidden by one that merely defaults to it, and a
    /// "Don't record" app never hides another call. It still counts when nothing else is live (the tracker keeps its
    /// episode).
    public static func detect(of users: [MicUser], tab: (String) -> BrowserTabURL.Result,
                              mode: (String) -> CallAppMode = CallPolicy.defaultMode) -> Detection {
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
            let lRank = rank(mode(l.source)), rRank = rank(mode(r.source))
            if lRank != rRank { return lRank < rRank }
            if l.bundleID != r.bundleID { return l.bundleID < r.bundleID }
            return l.source < r.source
        }
        return Detection(call: best, browserDenied: best == nil && denied, browserUnreadable: best == nil && unreadable)
    }

    private static func rank(_ mode: CallAppMode) -> Int {
        switch mode {
        case .auto: return 0
        case .ask: return 1
        case .never: return 2
        }
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

    /// The sources a browser tab can turn out to be (`MeetingURL.source`): a browser is read only while one of
    /// them is not "Don't record".
    public static let browserSources: Set<String> = ["meet", "zoom", "oxpulse", "teams"]

    /// The display name of a browser, for the Automation-consent badge ("A call in Chrome?…").
    public static func browserName(_ bundleID: String) -> String {
        ["com.google.Chrome": "Chrome", "com.brave.Browser": "Brave",
         "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Edge"][bundleID] ?? bundleID
    }
}

/// macOS's answer for "may ox-say send this browser an Apple Event", asked WITHOUT prompting
/// (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`, in the app target).
public enum BrowserConsent: Equatable {
    /// Automation was already allowed — or macOS declined to answer; the read decides, as before.
    case granted
    /// Automation is off.
    case denied
    /// Nobody was asked yet: the first Apple Event would raise macOS's Automation prompt with no context,
    /// so the badge asks first.
    case undetermined
}

/// Recognizes a meeting page by its address.
public enum MeetingURL {
    /// An OxPulse call room (oxpulse-chat docs/url-contract.md): `/<22-char id>` (1:1), `/<LLLL-DDDDC>` or
    /// `/r/<LLLL-DDDD…>` (group). The landing pages, the chat app (`/app/…`) and the burner/sealed chat shims
    /// (`/c/…`, `/m/…`, or `?hint=burner|sealed`) are not calls.
    private static func oxPulseIsRoom(_ url: URL) -> Bool {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let hint = comps?.queryItems?.first(where: { $0.name == "hint" })?.value, hint == "burner" || hint == "sealed" { return false }
        let path = url.path
        let shapes = ["^/[A-Za-z0-9_-]{22}$", "^/[A-Z]{4}-[0-9]{4}[0-9A-Z]?$", "^/r/[A-Z]{4}-[0-9]{4}[0-9A-Z]?$"]
        return shapes.contains { path.range(of: $0, options: .regularExpression) != nil }
    }

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
        if host == "oxpulse.chat" || host.hasSuffix(".oxpulse.chat") {
            return oxPulseIsRoom(url) ? "oxpulse" : nil
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
    /// Episodes (`call|bundleID`) already offered or recorded, and ones the user declined. They are remembered
    /// per episode, not as one flag: two call holders that alternate (a Zoom app and a Meet tab) each keep their own
    /// answer, so a decline of one is not forgotten when the other comes and goes (#241). The idle reset below
    /// clears both.
    private var announcedKeys: Set<String> = []
    private var declinedKeys: Set<String> = []
    /// `decline()` came while no episode existed yet: it applies to the next one.
    private var declineNext = false
    /// Which app/page the current call episode belongs to; a different one is a new call.
    private var episode: String?
    /// Consecutive ticks on which a browser held the microphone but its tab was unreadable.
    private var unreadableTicks = 0

    /// The episode the tracker is in (nil between calls): `call|bundleID`, as `observe` keys it.
    public var episodeKey: String? { episode }

    public static func key(call: String, bundleID: String?) -> String { call + "|" + (bundleID ?? "") }

    public init() {}

    /// Forget the current call: the user said "don't record this one". The
    /// call is not offered again until it has ended.
    public mutating func decline() {
        if let episode { declinedKeys.insert(episode) } else { declineNext = true }
    }

    /// One observation. `call` is the detected source or nil; `bundleID` is the app
    /// that holds it (a change of source or app starts a new call episode);
    /// `themActive` is whether the other side was audible lately; `recording` is
    /// nil when idle, else how the recording began (only an auto-started one is
    /// stopped here); `callUnreadable` says a browser held the microphone but its
    /// tab could not be read — one such tick does not break the debounce.
    /// `heldOnly` says `call` is only the current episode's memory (its browser
    /// still holds the microphone, the page in front is not a call page): it keeps
    /// the episode's identity — a decline or a user stop stands — but is not a live
    /// call: it never starts or offers a recording, and an auto recording's silence
    /// timer keeps running. Ignored unless `call` is the current episode.
    public mutating func observe(now: Date, call: String?, themActive: Bool, recording: Origin?,
                                 bundleID: String? = nil, callUnreadable: Bool = false, heldOnly: Bool = false) -> Action {
        let key = call.map { Self.key(call: $0, bundleID: bundleID) }
        let held = heldOnly && key != nil && key == episode
        if held, recording != .auto {
            // The call page is not in front but the browser still holds the microphone:
            // the episode goes on, nothing is offered, and the debounce starts over when
            // the call page returns.
            unreadableTicks = 0
            callSince = nil
            quietSince = nil
            idleSince = nil
            if recording != nil, let episode { announcedKeys.insert(episode) }
            return .nothing
        }
        if let call, !held {
            unreadableTicks = 0
            quietSince = nil
            idleSince = nil
            if let episode, episode != key { callSince = nil }
            episode = key
            if declineNext, let key {
                declinedKeys.insert(key)
                declineNext = false
            }
            if callSince == nil { callSince = now }
            if recording != nil {
                // A recording is already running (the user started it, or we did): this
                // call is taken care of. When it stops while the call goes on, a user's
                // stop stays stopped; only an automatic stop re-arms (below).
                if let key { announcedKeys.insert(key) }
                return .nothing
            }
            if let key, !announcedKeys.contains(key), !declinedKeys.contains(key),
               now.timeIntervalSince(callSince!) >= Self.startAfter {
                announcedKeys.insert(key)
                return .callStarted(source: call)
            }
            return .nothing
        }
        if callUnreadable, !held, callSince != nil, unreadableTicks < 1 {
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
                    if let episode { announcedKeys.remove(episode) }
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
                announcedKeys = []
                declinedKeys = []
                declineNext = false
                episode = nil
            }
        }
        return .nothing
    }
}

/// One polling round of the call watcher: the microphone users go in, the
/// detection and the tracker action come out. This is the piece the AppKit
/// timer cannot decide for itself: a browser call stays a call while its
/// browser holds the microphone — leaving the call tab is not hanging up, so
/// a user stop or a "don't record this one" survives it (#241) — and a denied
/// tab read is reported, not mistaken for "no call".
public struct CallWatch {
    /// What one round adds up to.
    public struct Outcome: Equatable {
        /// The call that counts this round: the detected one, else the call in
        /// progress while its app still holds the microphone.
        public var call: CallDetector.Detection.Call?
        /// `call` is the episode's memory, not a page that reads as a call right
        /// now: the tracker keeps its decline / user stop, never starts a recording
        /// from it, and lets an auto recording's silence timer run.
        public var heldOnly = false
        /// What the tracker made of the round.
        public var action: CallTracker.Action
        /// A browser held the microphone and Automation for it is off — the app
        /// must say so (notice.meeting.browser_denied): it looks exactly like
        /// no call. Reported again after a read for that browser worked in between.
        public var browserDenied = false
        /// A browser has held the microphone for several rounds in a row and its tab was never readable: an
        /// Automation prompt that nobody answered looks like this (#251). Reported once, until a read works.
        public var browserNeedsPermission = false
        /// A browser held the microphone while its Automation consent is undetermined — it must be asked in
        /// context before the first Apple Event, so the round names it instead of reading its tab.
        public var browserNeedsConsent: String?
    }

    /// Polls (2 s apart) of unreadable tab before the app says it is waiting for permission: long enough that one
    /// slow read or a browser without a window stays silent.
    public static let unreadableRoundsBeforeNotice = 5

    private var unreadableRounds = 0
    private var permissionReported = false
    private var tracker = CallTracker()
    /// The call last seen live. It is the episode's memory: consulted only while its
    /// app still holds the microphone AND the tracker is still in that episode, and
    /// dropped the moment either stops being true — a browser that grabs the
    /// microphone for another site hours later is not that call.
    private var lastCall: CallDetector.Detection.Call?
    /// Browsers whose denied read was already reported. A browser leaves the set when
    /// a read of it works, so a revoke after a grant is reported again.
    private var deniedReported: Set<String> = []
    /// Browsers the user already said "Allow…" to this episode: their read goes out (the macOS prompt
    /// it raises is answered there), and the consent check is not run for them again.
    private var consentAsked: Set<String> = []
    /// Browsers the user said "Not now" to: no Apple Event for them until they let the microphone go.
    private var skippedConsent: Set<String> = []
    /// macOS's decided Automation answers, kept while the browser holds the microphone: the lookup is a TCC query
    /// and the poll runs every 2 s. An undetermined answer is never kept — the user may settle it any moment.
    private var consentCache: [String: BrowserConsent] = [:]

    public init() {}

    /// Forget the current call: the user said "don't record this one". The
    /// call is not offered again until it has ended.
    public mutating func decline() { tracker.decline() }

    /// "Allow…" was clicked for this browser: its next read is the real one (and raises macOS's prompt).
    public mutating func consentAsked(_ id: String) { consentAsked.insert(id); skippedConsent.remove(id) }

    /// "Not now" was clicked: no Apple Event to this browser until it releases the microphone.
    public mutating func skipConsent(_ id: String) { skippedConsent.insert(id) }

    /// `tab` reads a browser's front page (BrowserTabURL.read in the app); the rest
    /// is what CallTracker.observe takes. `recording` is nil when no recording runs.
    /// `mode`: the user's pick per source (see `CallDetector.detect`).
    /// `consent` is macOS's Automation answer for a browser WITHOUT asking (`BrowserConsent`); a browser
    /// whose answer is undetermined gets no Apple Event — the round names it for the in-context badge.
    public mutating func observe(now: Date, users: [MicUser], tab: (String) -> BrowserTabURL.Result,
                                 themActive: Bool, recording: CallTracker.Origin?,
                                 mode: (String) -> CallAppMode = CallPolicy.defaultMode,
                                 consent: (String) -> BrowserConsent = { _ in .granted }) -> Outcome {
        // A browser tab can only turn out to be a call source the user did not switch off: with all of them
        // on "Don't record" no browser is asked about, let alone read.
        let browsersWanted = CallDetector.browserSources.contains { mode($0) != .never }
        var browserIDs: Set<String> = []
        for user in users {
            let id = CallDetector.canonical(user.bundleID)
            if browsersWanted, CallDetector.browsers.contains(id) { browserIDs.insert(id) }
        }
        let detectUsers = browsersWanted ? users : users.filter { !CallDetector.browsers.contains(CallDetector.canonical($0.bundleID)) }
        // A browser that let the microphone go is a new hold on its next grab: "Not now" and "Allow…" are
        // forgotten (a later Automation reset is asked in context again) and so is the cached answer.
        skippedConsent.formIntersection(browserIDs)
        consentAsked.formIntersection(browserIDs)
        consentCache = consentCache.filter { browserIDs.contains($0.key) }
        var needsConsent: Set<String> = []
        for id in browserIDs where !skippedConsent.contains(id) && !consentAsked.contains(id) {
            let answer = consentCache[id] ?? consent(id)
            if answer == .undetermined { needsConsent.insert(id) } else { consentCache[id] = answer }
        }
        var reads: [String: BrowserTabURL.Result] = [:]
        let detection = CallDetector.detect(of: detectUsers, tab: { id in
            // Undetermined or skipped: no Apple Event, and the answer is not a real read — neither the
            // debounce tolerance nor the "waiting for permission" count may see it.
            if needsConsent.contains(id) || skippedConsent.contains(id) { return .unreadable }
            let result = tab(id)
            reads[id] = result
            return result
        }, mode: mode)
        var call = detection.call
        var heldOnly = false
        // A browser call goes on while that browser holds the microphone,
        // whichever tab is in front (#241) — as the same episode, never as a new call.
        if call == nil, let last = lastCall {
            if CallDetector.holds(users, bundleID: last.bundleID),
               tracker.episodeKey == CallTracker.key(call: last.source, bundleID: last.bundleID) {
                call = last
                heldOnly = true
            } else {
                lastCall = nil
            }
        }
        if let call, !heldOnly { lastCall = call }
        // Only reads that actually went out count: a consent-gated browser is neither a stalled read
        // for the debounce nor a "waiting for permission" below.
        let realUnreadable = detection.call == nil && reads.values.contains(.unreadable)
        let action = tracker.observe(now: now, call: call?.source, themActive: themActive,
                                     recording: recording, bundleID: call?.bundleID,
                                     callUnreadable: realUnreadable, heldOnly: heldOnly)
        for (id, result) in reads {
            if case .url = result { deniedReported.remove(id) }
        }
        var denied = false
        if detection.browserDenied {
            let fresh = reads.filter { $0.value == .denied }.keys.filter { !deniedReported.contains($0) }
            if !fresh.isEmpty {
                denied = true
                deniedReported.formUnion(fresh)
            }
        }
        // Unreadable rounds in a row, with no call found and no read that worked this round.
        var needsPermission = false
        if realUnreadable, !reads.values.contains(where: { if case .url = $0 { return true } else { return false } }) {
            unreadableRounds += 1
            if unreadableRounds >= Self.unreadableRoundsBeforeNotice, !permissionReported {
                permissionReported = true
                needsPermission = true
            }
        } else {
            unreadableRounds = 0
            if reads.values.contains(where: { if case .url = $0 { return true } else { return false } }) { permissionReported = false }
        }
        return Outcome(call: call, heldOnly: heldOnly, action: action, browserDenied: denied,
                       browserNeedsPermission: needsPermission, browserNeedsConsent: needsConsent.sorted().first)
    }
}
