import Foundation

/// Which kind of web-engine app the frontmost app is. Chromium and Electron
/// publish no focused element over Accessibility until a client asks for the
/// tree, and each answers to its own switch (#220).
public enum WebAppKind: String, Equatable {
    case chromium, electron

    /// The AX attribute that makes this kind publish its tree.
    public var attribute: String {
        switch self {
        case .chromium: return "AXEnhancedUserInterface"
        case .electron: return "AXManualAccessibility"
        }
    }

    /// Bundle ids known at once, without listing the bundle. A shortcut only:
    /// the bundle's own frameworks decide for an app no list knows.
    private static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "company.thebrowser.Browser",
        "company.thebrowser.dia",
    ]
    private static let electronIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "notion.id", "md.obsidian", "com.figma.Desktop",
    ]

    /// nil for an app that is neither: it is never touched.
    public static func classify(_ app: AppIdentity) -> WebAppKind? {
        if let id = app.bundleID {
            if electronIDs.contains(id) { return .electron }
            if chromiumIDs.contains(id) { return .chromium }
        }
        // The bundle decides for the rest: Electron ships its own framework; CEF
        // embedders ship the CEF framework; a Chromium browser ships
        // "<Name> Framework.framework" whose own Versions/*/Helpers holds
        // "<Name> Helper*.app" (the real layout of Chrome and Brave; the framework
        // dir alone is not enough: Sparkle or an SDK has no helpers). Listed
        // lazily: only here, when the bundle id did not decide.
        let entries = app.list("Frameworks")
        if entries.contains("Electron Framework.framework") { return .electron }
        if entries.contains("Chromium Embedded Framework.framework") { return .chromium }
        let suffix = " Framework.framework"
        for entry in entries where entry.hasSuffix(suffix) {
            let name = String(entry.dropLast(suffix.count))
            guard !name.isEmpty else { continue }
            let versions = "Frameworks/\(entry)/Versions"
            for version in app.list(versions) {
                if app.list("\(versions)/\(version)/Helpers")
                    .contains(where: { $0.hasPrefix(name + " Helper") && $0.hasSuffix(".app") }) {
                    return .chromium
                }
            }
        }
        return nil
    }
}

/// The frontmost app as classification sees it: its bundle id and a lister of
/// directories inside its `Contents` (names only, relative path such as
/// "Frameworks"). A closure, so classification lists the bundle only when the
/// bundle id did not decide, and runs against fixture trees in tests.
public struct AppIdentity {
    public var bundleID: String?
    public var list: (String) -> [String]

    public init(bundleID: String?, list: @escaping (String) -> [String]) {
        self.bundleID = bundleID
        self.list = list
    }

    /// The real bundle: directory listings only, nothing is opened or run.
    public static func onDisk(bundleID: String?, contents: URL?) -> AppIdentity {
        AppIdentity(bundleID: bundleID) { path in
            guard let contents else { return [] }
            let dir = contents.appendingPathComponent(path).path
            return (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        }
    }
}

/// What reading one boolean attribute of an app's AXApplication element gave.
public enum AXAttributeValue: Equatable {
    case bool(Bool)
    /// The app does not publish the attribute for reading (settable all the same).
    case unsupported
    /// Any other AXError (raw value).
    case error(Int32)

    /// One `AXUIElementCopyAttributeValue` outcome as a value. `boolean` is the
    /// value when it came back as a CFBoolean, nil for any other type. A success
    /// that is not a boolean is an error, never "off": an unknown value must not
    /// be read as a licence to switch the attribute off.
    public static func decode(error: Int32, boolean: Bool?) -> AXAttributeValue {
        switch error {
        case 0: return boolean.map { .bool($0) } ?? .error(-25201) // kAXErrorIllegalArgument
        case -25205, -25212: return .unsupported // kAXErrorAttributeUnsupported, kAXErrorNoValue
        default: return .error(error)
        }
    }
}

/// The AX seam for the application element's boolean attributes. The real one
/// lives in the app target; tests use a fake and never touch a running app.
public protocol AXAppAttributes {
    func read(_ name: String) -> AXAttributeValue
    /// The raw AXError of the write, 0 on success.
    func write(_ name: String, _ value: Bool) -> Int32
}

/// Whether the attribute goes back to what it was once the read is done.
public enum WakePolicy: Equatable {
    /// Put the previous value back (AXEnhancedUserInterface makes some apps
    /// animate window moves badly while it stays on).
    case restore
    case leave
}

/// What a wake did, content-free: it feeds the log line.
public struct AXWake: Equatable {
    public enum Outcome: Equatable {
        /// The retry read answered (text, or a secure field).
        case found
        /// The attribute was set and the retries still found no selection.
        case nothing
        /// The attribute was already on; nothing was changed.
        case alreadyOn
        /// VoiceOver or Switch Control is on: the attribute is never written.
        case assistiveTech
        case setFailed(Int32)
        case readFailed(Int32)

        var label: String {
            switch self {
            case .found: return "found"
            case .nothing: return "nothing"
            case .alreadyOn: return "already-on"
            case .assistiveTech: return "assistive-tech"
            case .setFailed(let c): return "set-failed(\(c))"
            case .readFailed(let c): return "read-failed(\(c))"
            }
        }
    }

    public var kind: WebAppKind
    public var outcome: Outcome
    /// The raw AXError of the restore write; 0 when it succeeded or none was due.
    public var restoreError: Int32

    public init(kind: WebAppKind, outcome: Outcome, restoreError: Int32 = 0) {
        self.kind = kind
        self.outcome = outcome
        self.restoreError = restoreError
    }

    /// `chromium:found`, plus ` restore=<code>` when the restore failed.
    var logText: String {
        "\(kind.rawValue):\(outcome.label)" + (restoreError == 0 ? "" : " restore=\(restoreError)")
    }
}

/// Asks a Chromium/Electron app for its AX tree when the selection read found
/// nothing, then reads again. Only for such an app; any other is untouched.
public enum ChromiumAXWake {
    /// How long the tree is given to appear after the set, in whole `step`s.
    public static let wait: TimeInterval = 0.4
    public static let step: TimeInterval = 0.05
    /// The one place the reset policy is chosen.
    public static let defaultPolicy: WakePolicy = .restore

    /// - Parameters:
    ///   - first: the ordinary AX read. With text or a secure field it is returned as it is.
    ///   - identity: the frontmost app; asked only when `first` has no text.
    ///   - attributes: its AXApplication element.
    ///   - assistiveTechOn: VoiceOver or Switch Control is running. Then the attribute is
    ///     NOT written at all: the user's tree may depend on it, and a write (even the
    ///     restore) could drop it; the press falls to the ordinary path.
    ///   - retry: the same selection read again.
    ///   - spin: pumps the run loop for the given seconds between retries.
    ///   - now: the clock the wait is measured on.
    /// - Returns: the retry's read when it answered, else `first`; `wake` says what was tried.
    ///
    /// Time: `wait` is a deadline on `now`. No retry starts once it has passed, but an
    /// AX call already begun runs to its own 0.3 s messaging timeout, so a hung app costs
    /// at most `wait` + one read (the system-wide and the app source, 3 calls each) +
    /// the read of the old value, the set and the restore, about 0.4 + 1.8 + 0.9 s.
    ///
    /// Restore: the value goes back only when its read returned an actual `false`. When
    /// it was unknowable (`.unsupported`: Electron does not publish AXManualAccessibility
    /// for reading) nothing is written back, so a tree somebody else relies on is never
    /// switched off; for Electron the attribute is the documented, glitch-free switch.
    public static func read(first: AXSelection,
                            identity: () -> AppIdentity?,
                            attributes: AXAppAttributes,
                            assistiveTechOn: () -> Bool = { false },
                            retry: () -> AXSelection,
                            spin: (TimeInterval) -> Void,
                            now: () -> Date,
                            policy: WakePolicy = defaultPolicy) -> AXSelection {
        if first.hasText || first.secureField { return first }
        guard let app = identity(), let kind = WebAppKind.classify(app) else { return first }
        var base = first
        if assistiveTechOn() {
            base.wake = AXWake(kind: kind, outcome: .assistiveTech)
            return base
        }
        let name = kind.attribute
        var knownOff = false
        switch attributes.read(name) {
        case .error(let code):
            // The old value is unknown: it could not be put back, so it is not changed.
            base.wake = AXWake(kind: kind, outcome: .readFailed(code))
            return base
        case .bool(true):
            // Already on: the first read had the tree, a retry changes nothing.
            base.wake = AXWake(kind: kind, outcome: .alreadyOn)
            return base
        case .bool(false):
            knownOff = true
        case .unsupported:
            break
        }
        let setError = attributes.write(name, true)
        if setError != 0 {
            base.wake = AXWake(kind: kind, outcome: .setFailed(setError))
            return base
        }
        let deadline = now().addingTimeInterval(wait)
        var result = base
        var outcome = AXWake.Outcome.nothing
        while true {
            let next = retry()
            if next.hasText || next.secureField {
                result = next
                result.trail = first.attempts + next.attempts
                outcome = .found
                break
            }
            // The deadline is checked before every AX call, not only after the pauses.
            let remaining = deadline.timeIntervalSince(now())
            if remaining <= 0.001 { break }
            spin(min(step, remaining))
            if deadline.timeIntervalSince(now()) <= 0.001 { break }
        }
        let restoreError = (policy == .restore && knownOff) ? attributes.write(name, false) : 0
        result.wake = AXWake(kind: kind, outcome: outcome, restoreError: restoreError)
        return result
    }
}
