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
        "com.hnc.Discord", "notion.id", "md.obsidian", "com.figma.Desktop", "com.spotify.client",
    ]

    /// nil for an app that is neither: it is never touched.
    public static func classify(_ app: AppIdentity) -> WebAppKind? {
        if let id = app.bundleID {
            if electronIDs.contains(id) { return .electron }
            if chromiumIDs.contains(id) { return .chromium }
        }
        // The bundle decides for the rest: Electron ships its own framework; a
        // Chromium browser ships "<Name> Framework.framework" beside
        // "<Name> Helper*.app"; CEF embedders ship the CEF framework. A framework
        // with no matching helper (Sparkle, an SDK) is not an engine.
        let entries = app.frameworks
        if entries.contains("Electron Framework.framework") { return .electron }
        if entries.contains("Chromium Embedded Framework.framework") { return .chromium }
        let suffix = " Framework.framework"
        for entry in entries where entry.hasSuffix(suffix) {
            let name = String(entry.dropLast(suffix.count))
            if !name.isEmpty, entries.contains(where: { $0.hasPrefix(name + " Helper") && $0.hasSuffix(".app") }) {
                return .chromium
            }
        }
        return nil
    }
}

/// What the app target learned about the frontmost app: its bundle id and the
/// entries of its `Contents/Frameworks`. Plain values, so classification runs
/// against fixtures.
public struct AppIdentity: Equatable {
    public var bundleID: String?
    public var frameworks: [String]

    public init(bundleID: String?, frameworks: [String]) {
        self.bundleID = bundleID
        self.frameworks = frameworks
    }
}

/// What reading one boolean attribute of an app's AXApplication element gave.
public enum AXAttributeValue: Equatable {
    case bool(Bool)
    /// The app does not publish the attribute for reading (settable all the same).
    case unsupported
    /// Any other AXError (raw value).
    case error(Int32)
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
        case setFailed(Int32)
        case readFailed(Int32)

        var label: String {
            switch self {
            case .found: return "found"
            case .nothing: return "nothing"
            case .alreadyOn: return "already-on"
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
    ///   - retry: the same selection read again.
    ///   - spin: pumps the run loop for the given seconds between retries.
    ///   - now: the clock the wait is measured on, so a slow AX call spends the budget too.
    /// - Returns: the retry's read when it answered, else `first`; `wake` says what was tried.
    public static func read(first: AXSelection,
                            identity: () -> AppIdentity?,
                            attributes: AXAppAttributes,
                            retry: () -> AXSelection,
                            spin: (TimeInterval) -> Void,
                            now: () -> Date,
                            policy: WakePolicy = defaultPolicy) -> AXSelection {
        if first.hasText || first.secureField { return first }
        guard let app = identity(), let kind = WebAppKind.classify(app) else { return first }
        let name = kind.attribute
        var base = first
        switch attributes.read(name) {
        case .error(let code):
            // The old value is unknown: it could not be put back, so it is not changed.
            base.wake = AXWake(kind: kind, outcome: .readFailed(code))
            return base
        case .bool(true):
            // Already on: the first read had the tree, a retry changes nothing.
            base.wake = AXWake(kind: kind, outcome: .alreadyOn)
            return base
        case .bool(false), .unsupported:
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
        repeat {
            // Never past the deadline: the last pause is cut to what is left.
            spin(max(0, min(step, deadline.timeIntervalSince(now()))))
            let next = retry()
            if next.hasText || next.secureField {
                result = next
                result.trail = first.attempts + next.attempts
                outcome = .found
                break
            }
        } while deadline.timeIntervalSince(now()) > 0.001
        let restoreError = policy == .restore ? attributes.write(name, false) : 0
        result.wake = AXWake(kind: kind, outcome: outcome, restoreError: restoreError)
        return result
    }
}
