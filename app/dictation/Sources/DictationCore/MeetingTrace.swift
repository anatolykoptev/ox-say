import Foundation

/// The meeting prompt and recording transitions, as the log lines the `meeting` category carries (#518): what was
/// shown, what the user answered, what was started, refused or failed and why. Public data only — the app's name,
/// ids and tokens; never a window title or a URL.
public enum MeetingTrace {
    public enum Choice: String, Equatable {
        case record
        case notNow = "not_now"
        case dontAsk = "dont_ask"
        case cancel
    }

    public enum Event: Equatable {
        case promptShown(app: String)
        case answered(Choice, app: String)
        case checking(holder: String)
        case checked(RecordCheck.Verdict, stale: Bool, tabs: String)
        case autoStarting(app: String)
        case autoIgnored(app: String, reason: String)
        case startRequested(origin: String, offered: Bool, app: String)
        case startRefused(reason: String)
        case started(id: String, origin: String)
        case startFailed(reason: String)
        case stopped(id: String, why: String)

        public var line: String {
            switch self {
            case .promptShown(let app): return "prompt shown app=\(app)"
            case .answered(let choice, let app): return "prompt answered choice=\(choice.rawValue) app=\(app)"
            case .checking(let holder): return "record check holder=\(holder)"
            case .checked(let verdict, let stale, let tabs):
                return "record check verdict=\(verdict == .record ? "record" : "ask") stale=\(stale) tabs=\(tabs)"
            case .autoStarting(let app): return "auto record app=\(app)"
            case .autoIgnored(let app, let reason): return "call ignored app=\(app) reason=\(MeetingTrace.sanitized(reason))"
            case .startRequested(let origin, let offered, let app):
                return "start requested origin=\(origin) offered=\(offered) app=\(MeetingTrace.sanitized(app))"
            case .startRefused(let reason): return "start refused reason=\(MeetingTrace.sanitized(reason))"
            case .started(let id, let origin): return "started id=\(id) origin=\(origin)"
            case .startFailed(let reason): return "start failed reason=\(MeetingTrace.sanitized(reason))"
            case .stopped(let id, let why): return "stopped id=\(id) why=\(MeetingTrace.sanitized(why))"
            }
        }
    }

    /// A reason as a token. Free text can carry a title or an address: anything that looks like one, or is long, is
    /// "redacted".
    public static func sanitized(_ text: String) -> String {
        if text.isEmpty { return "unknown" }
        if text.contains("/") || text.count > 40 { return "redacted" }
        let token = text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }
        let collapsed = String(token).replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// The error's type, never its text (a daemon message can echo a title).
    public static func reason(of error: Error) -> String {
        let name = String(describing: type(of: error))
        let snake = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
        return sanitized(snake)
    }
}
