import Foundation

/// What one Accessibility read of the focused element found. Plain values, so
/// the decisions made on it (which source wins, what a secure field means)
/// run against fakes in tests; the real AX calls live in the app target.
public struct AXSelection: Equatable {
    /// Which AX element the read started from.
    public enum Source: String, Equatable {
        /// `AXUIElementCreateSystemWide()` → focused element.
        case systemWide = "systemwide"
        /// The frontmost app's own element → focused element.
        case app
    }

    /// The focused element's AXSelectedText; nil when it had none.
    public var text: String?
    /// The focused element is an `AXSecureTextField` (its subrole).
    public var secureField: Bool
    /// A focused element came back. False sends the read to the next source.
    public var hasElement: Bool
    /// The raw AXError of the step that failed, 0 when every step succeeded.
    public var error: Int32
    public var source: Source
    /// Every source `read` asked, in order, when it asked more than one; empty
    /// for a single read. Content-free: it feeds the log line.
    public var trail: [Attempt]
    /// What waking a Chromium/Electron app for this read did; nil when no wake was tried.
    public var wake: AXWake?

    /// What one source's read came to, without its content.
    public struct Attempt: Equatable {
        public var source: Source
        public var error: Int32
        /// The element was a secure field: its text was dropped, so the error
        /// code (0 for a successful read) says nothing about the outcome.
        public var secure: Bool

        public init(source: Source, error: Int32, secure: Bool = false) {
            self.source = source
            self.error = error
            self.secure = secure
        }
    }

    public init(text: String? = nil, secureField: Bool = false, hasElement: Bool,
                error: Int32, source: Source, trail: [Attempt] = [], wake: AXWake? = nil) {
        self.text = text
        self.secureField = secureField
        self.hasElement = hasElement
        self.error = error
        self.source = source
        self.trail = trail
        self.wake = wake
    }

    /// This read as one log entry.
    public var attempt: Attempt { Attempt(source: source, error: error, secure: secureField) }

    /// Every source asked for this read, in order.
    public var attempts: [Attempt] { trail.isEmpty ? [attempt] : trail }

    /// The system-wide element first; the frontmost app's own element when it
    /// yields no focused element or no selected text. The system-wide query is
    /// refused for some callers (kAXErrorCannotComplete, -25204), answers with
    /// no element for apps that publish their tree per-process, and for others
    /// (Chromium) returns an element with no AXSelectedText, so one source
    /// alone is not enough. The app source is asked only after the first one
    /// has no text. A secure field from either source is returned as it is, so
    /// it is refused whole; the result carries both sources' outcomes in `trail`.
    public static func read(systemWide: () -> AXSelection, app: () -> AXSelection) -> AXSelection {
        var first = systemWide()
        if first.secureField || first.hasText { return first }
        var second = app()
        let trail = [first.attempt, second.attempt]
        first.trail = trail
        second.trail = trail
        if second.secureField || second.hasText { return second }
        return first.hasElement ? first : second
    }

    /// A non-empty selected text; an empty string is "no selection" to AX.
    var hasText: Bool { !(text ?? "").isEmpty }
}

/// Which way a speak press got its text.
public enum SelectionPath: String, Equatable {
    case ax, copy, none
    /// Declined: AX gave nothing and ⌘C would have replaced an iPhone copy.
    case remote
}

/// One speak press, reduced to what the log needs to tell the paths apart:
/// no content, ever.
public struct SelectionReport: Equatable {
    public var path: SelectionPath
    public var attempts: [AXSelection.Attempt]
    public var wake: AXWake?

    public init(path: SelectionPath, attempts: [AXSelection.Attempt], wake: AXWake? = nil) {
        self.path = path
        self.attempts = attempts
        self.wake = wake
    }

    /// `selection path=ax|copy|none|remote ax=<source>:<code>[,<source>:<code>]`
    /// — one entry per source asked, in order; `secure` stands in for the code
    /// of a secure field (its text was dropped, so 0 would read as a success).
    public var line: String {
        let asked = attempts.map { "\($0.source.rawValue):\($0.secure ? "secure" : String($0.error))" }
        return "selection path=\(path.rawValue) ax=\(asked.joined(separator: ","))"
            + (wake.map { " wake=\($0.logText)" } ?? "")
    }
}
