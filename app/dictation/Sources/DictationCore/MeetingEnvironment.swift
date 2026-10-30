import Foundation

/// Whether the call is heard through speakers — the case where the microphone
/// re-captures the far side and the daemon drops the duplicated words. It errs
/// toward "speakers": mistaking headphones for speakers costs a gate that finds
/// nothing to drop; the other mistake leaves the far side written twice.
public enum OutputRoute {
    /// Names that say the device is worn on the head or sits in the ear. A Bluetooth
    /// output carries no such hint in its transport type — JBL, Jabra Speak, Poly
    /// Sync, HomePod and a car are all "blue" — so only a name can vouch for it.
    ///
    /// Added for en/ru/de (#241). Sources: Bose "QuietComfort" is headphones and earbuds only (Wikipedia, Bose
    /// Corporation); Anker's Soundcore worn lines are Liberty, Life (incl. Life Q), P and Space, its speakers Flare,
    /// Rave, Boom, Motion (Wikipedia, Anker Innovations; bare "soundcore" is therefore NOT a headphone word); Jabra
    /// Elite is the earbud/headphone line, Speak the speakerphone line; the Russian and German words for headphones.
    static let headphoneWords = ["airpods", "beats", "buds", "earbuds", "headphone", "headset", "earphone",
                                 "quietcomfort", "jabra elite", "soundcore liberty", "soundcore life", "soundcore space",
                                 "наушник", "гарнитур", "kopfhörer", "ohrhörer"]
    /// Beats makes speakers too.
    static let speakerWords = ["pill"]
    /// Model prefixes: Sony WH-/WF-, Bose QC.
    static let headphonePrefixes = ["wh-", "wf-", "qc"]

    static func namesHeadphones(_ name: String) -> Bool {
        // NFC first: macOS reports names decomposed ("o" + U+0308) as often as precomposed.
        let lowered = name.precomposedStringWithCanonicalMapping.lowercased()
        if speakerWords.contains(where: lowered.contains) { return false }
        if headphoneWords.contains(where: lowered.contains) { return true }
        let tokens = lowered.split(whereSeparator: { $0 == " " || $0 == "\u{2019}" || $0 == "'" })
        return tokens.contains { token in headphonePrefixes.contains { token.hasPrefix($0) } }
    }

    /// `transport`: the output device's transport type as its four-character code
    /// ("bltn" built-in, "blue"/"blea" Bluetooth, "usb ", "hdmi"…). `dataSource`: the
    /// built-in device's selected data source ("ispk" internal speakers, "hdpn"
    /// headphones), nil when it has none.
    public static func isLikelySpeakers(transport: String, dataSource: String?, name: String) -> Bool {
        if namesHeadphones(name) { return false }
        if transport == "bltn" { return dataSource != "hdpn" }
        return true
    }
}

/// The address of a browser's front tab, asked through Apple Events, only when
/// a browser holds the microphone.
public enum BrowserTabURL {
    /// Nothing is launched: the script runs only if the browser already is.
    public static func script(bundleID: String) -> String? {
        // The id is spliced into AppleScript source: refuse anything but a bundle id.
        guard bundleID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return """
        if application id "\(bundleID)" is running then
            with timeout of 1 second
                tell application id "\(bundleID)" to return URL of active tab of front window
            end timeout
        end if
        return ""
        """
    }

    public enum Result: Equatable {
        case url(String)
        case unreadable
        /// Automation for this browser is off: Meet cannot be told from any other page.
        case denied
    }

    public static func read(bundleID: String, runner: AppleScriptRunner) -> Result {
        guard let source = script(bundleID: bundleID) else { return .unreadable }
        switch runner.run(source, timeout: 1.5) {
        case .value(let text): return text.isEmpty ? .unreadable : .url(text)
        case .denied: return .denied
        case .timedOut, .failed: return .unreadable
        }
    }
}

/// Every tab of a browser, asked through Apple Events — the Record press's question (#342.1): the call the
/// prompt is about may have moved to a background tab the poll's front-tab read cannot see. Bounded like
/// the poll's read; every non-answer is `.unknown` to the caller.
public enum BrowserTabURLs {
    /// All windows' all tabs as one newline-joined text; a window that cannot answer does not sink the read
    /// of the rest. nil for anything that is not a bundle id — it is spliced into AppleScript source.
    public static func script(bundleID: String) -> String? {
        guard bundleID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return """
        if application id "\(bundleID)" is running then
            with timeout of 1 second
                tell application id "\(bundleID)"
                    set found to ""
                    set AppleScript's text item delimiters to linefeed
                    repeat with w in windows
                        try
                            set found to found & ((URL of every tab of w) as text) & linefeed
                        end try
                    end repeat
                    return found
                end tell
            end timeout
        end if
        return ""
        """
    }

    /// What the read answered, for `RecordCheck.decide`: some tab a call page, none, or no answer at all.
    public static func read(bundleID: String, runner: AppleScriptRunner) -> RecordCheck.Tabs {
        guard let source = script(bundleID: bundleID) else { return .unknown }
        switch runner.run(source, timeout: 1.5) {
        case .value(let text):
            return text.split(separator: "\n").contains { MeetingURL.source(of: String($0)) != nil } ? .callPage : .noCallPage
        case .denied, .timedOut, .failed:
            return .unknown
        }
    }
}
