import Foundation

/// How a failure is written to the unified log. The text of a daemon or engine body can echo what the person selected or
/// said, so an HTTP failure is logged as its status and the body's size at `.public`, the body itself only `.private`.
public enum LogDetail {
    public static func publicText(_ error: Error) -> String {
        switch error {
        case let e as SpeechError:
            if case .http(let code, let body) = e { return "http status=\(code) bodyBytes=\(body.utf8.count)" }
            return e.description
        case let e as TranscriptionError:
            if case .http(let code, let body) = e { return "http status=\(code) bodyBytes=\(body.utf8.count)" }
            return e.description
        default:
            return String(describing: error)
        }
    }

    /// The part that may hold the person's words; log it with `privacy: .private` only.
    public static func privateText(_ error: Error) -> String {
        switch error {
        case let e as SpeechError:
            if case .http(_, let body) = e { return body }
        case let e as TranscriptionError:
            if case .http(_, let body) = e { return body }
        default:
            break
        }
        return ""
    }
}
