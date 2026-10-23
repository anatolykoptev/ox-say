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

    public init(text: String? = nil, secureField: Bool = false, hasElement: Bool,
                error: Int32, source: Source) {
        self.text = text
        self.secureField = secureField
        self.hasElement = hasElement
        self.error = error
        self.source = source
    }

    /// The system-wide element first; the frontmost app's own element when it
    /// yields no focused element. The system-wide query is refused for some
    /// callers (kAXErrorCannotComplete, -25204) and answers with no element
    /// for apps that publish their tree per-process, so one source alone is
    /// not enough. The app source is asked only after the first one fails.
    public static func read(systemWide: () -> AXSelection, app: () -> AXSelection) -> AXSelection {
        let first = systemWide()
        return first.hasElement ? first : app()
    }
}

/// Which way a speak press got its text.
public enum SelectionPath: String, Equatable {
    case ax, copy, none
}

/// One speak press, reduced to what the log needs to tell the paths apart:
/// no content, ever.
public struct SelectionReport: Equatable {
    public var path: SelectionPath
    public var axError: Int32
    public var source: AXSelection.Source

    public init(path: SelectionPath, axError: Int32, source: AXSelection.Source) {
        self.path = path
        self.axError = axError
        self.source = source
    }

    /// `selection path=ax|copy|none ax_err=<code> source=systemwide|app`
    public var line: String {
        "selection path=\(path.rawValue) ax_err=\(axError) source=\(source.rawValue)"
    }
}
