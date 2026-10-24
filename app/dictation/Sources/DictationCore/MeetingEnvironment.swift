import Foundation

/// Whether the call is heard through speakers — the case where the microphone
/// re-captures the far side and the daemon drops the duplicated words. It errs
/// toward "speakers": mistaking headphones for speakers costs a gate that finds
/// nothing to drop; the other mistake leaves the far side written twice.
public enum OutputRoute {
    /// CoreAudio transport types worn on the head or sitting in the ear.
    static let headsetTransports: Set<String> = ["blue", "blea"]

    /// `transport`: the output device's transport type as its four-character code
    /// ("bltn" built-in, "blue"/"blea" Bluetooth, "usb ", "hdmi"…). `dataSource`: the
    /// built-in device's selected data source ("ispk" internal speakers, "hdpn"
    /// headphones), nil when it has none.
    public static func isLikelySpeakers(transport: String, dataSource: String?, name: String) -> Bool {
        if headsetTransports.contains(transport) { return false }
        let lowered = name.lowercased()
        if lowered.contains("airpods") || lowered.contains("headphone") || lowered.contains("headset") { return false }
        if transport == "bltn" { return dataSource != "hdpn" }
        return true
    }
}

/// The address of a browser's front tab, asked through Apple Events, only when
/// a browser holds the microphone.
public enum BrowserTabURL {
    /// Nothing is launched: the script runs only if the browser already is.
    public static func script(bundleID: String) -> String {
        """
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
        switch runner.run(script(bundleID: bundleID), timeout: 1.5) {
        case .value(let text): return text.isEmpty ? .unreadable : .url(text)
        case .denied: return .denied
        case .timedOut, .failed: return .unreadable
        }
    }
}
