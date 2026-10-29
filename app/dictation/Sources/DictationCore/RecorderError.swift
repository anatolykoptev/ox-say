import Foundation

/// Why the microphone could not start. `errorDescription` is English, for logs; `message(text:)` is what the person reads.
public enum RecorderError: LocalizedError, Equatable {
    case noInput
    case notAllowed
    case askedForPermission

    public var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available."
        case .notAllowed: return "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
        case .askedForPermission: return "Allow microphone access, then try again."
        }
    }

    public func message(text: (L10nKey) -> String = { $0.text }) -> String {
        switch self {
        case .noInput: return text(.recorderErrorNoInput)
        case .notAllowed: return text(.recorderErrorNotAllowed)
        case .askedForPermission: return text(.recorderErrorAskedForPermission)
        }
    }

    /// The reason after "Could not start recording:": the app's own words for a RecorderError, a plain fallback for any
    /// other error (the system's text is English on a Russian Mac for AVFoundation failures; the real error goes to the log).
    public static func reason(_ error: Error, text: (L10nKey) -> String = { $0.text }) -> String {
        (error as? RecorderError)?.message(text: text) ?? text(.noticeErrorFallback)
    }
}
