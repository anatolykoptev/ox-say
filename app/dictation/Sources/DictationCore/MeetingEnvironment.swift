import Foundation

/// Whether the call is heard through speakers — the case where the microphone
/// re-captures the far side and the daemon drops the duplicated words. It errs
/// toward "speakers": mistaking headphones for speakers costs a gate that finds
/// nothing to drop; the other mistake leaves the far side written twice.
public enum OutputRoute {
    /// Names that say the device is worn on the head or sits in the ear. A Bluetooth
    /// output carries no such hint in its transport type — JBL, Jabra Speak, Poly
    /// Sync, HomePod and a car are all "blue" — so only a name can vouch for it.
    static let headphoneWords = ["airpods", "beats", "buds", "earbuds", "headphone", "headset", "earphone"]
    /// Beats makes speakers too.
    static let speakerWords = ["pill"]
    /// Model prefixes: Sony WH-/WF-, Bose QC.
    static let headphonePrefixes = ["wh-", "wf-", "qc"]

    static func namesHeadphones(_ name: String) -> Bool {
        let lowered = name.lowercased()
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
